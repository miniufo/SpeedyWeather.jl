"""
$(TYPEDFIELDS)
"""
@kwdef struct Leapfrog{NF} <: TimeStepper{NF}

    # DIMENSIONS
    "spectral resolution (max degree of spherical harmonics)"
    trunc::Int                      


    # OPTIONS
    "time at which the integration starts"
    startdate::DateTime = DateTime(2000,1,1)
    
    "number of days to integrate for"
    n_days::Float64 = 10
    
    "time step in minutes for T31, scale linearly to `trunc`"
    Δt_at_T31::Float64 = 30

    "radius of sphere [m], used for scaling"
    radius::Float64 = 6.371e6

    # NUMERICS
    "Robert (1966) time filter coefficeint to suppress comput. mode"
    robert_filter::NF = 0.05

    "William's time filter (Amezcua 2011) coefficient for 3rd order acc"
    william_filter::NF = 0.53


    # DERIVED FROM OPTIONS    
    "time step Δt [s] at specified resolution"
    Δt_sec::Int = round(Int,60*Δt_at_T31*(32/(trunc+1)))

    "time step Δt [s/m] at specified resolution, scaled by 1/radius"
    Δt::NF = Δt_sec/radius
    
    "convert time step Δt from minutes to hours"
    Δt_hrs::Float64 = Δt_sec/3600

    "number of time steps to integrate for"
    n_timesteps::Int = ceil(Int,24*n_days/Δt_hrs)        
end

function Leapfrog(spectral_grid::SpectralGrid;kwargs...)
    (;NF,trunc,radius) = spectral_grid
    return Leapfrog{NF}(;trunc,radius,kwargs...)
end

function Base.show(io::IO,L::Leapfrog)
    println(io,"$(typeof(L))(")
    fields = propertynames(L)
    nfields = length(fields)
    for i in 1:nfields
        key = fields[i]
        val = getfield(L,key)
        s = "  $key::$(typeof(val)) = $val"
        if i < nfields println(io,s) else print(io,s*")") end
    end
end

"""
    leapfrog!(  A_old::LowerTriangularMatrix{Complex{NF}},      # prognostic variable at t
                A_new::LowerTriangularMatrix{Complex{NF}},      # prognostic variable at t+dt
                tendency::LowerTriangularMatrix{Complex{NF}},   # tendency (dynamics+physics) of A
                dt::Real,                                       # time step (=2Δt, but for init steps =Δt,Δt/2)
                lf::Int=2,                                      # leapfrog index to dis/enable William's filter
                C::DynamicsConstants{NF},                       # struct with constants used at runtime
                ) where {NF<:AbstractFloat}                     # number format NF

Performs one leapfrog time step with (`lf=2`) or without (`lf=1`) Robert+William's filter
(see William (2009), Montly Weather Review, Eq. 7-9).
"""
function leapfrog!( A_old::LowerTriangularMatrix{Complex{NF}},      # prognostic variable at t
                    A_new::LowerTriangularMatrix{Complex{NF}},      # prognostic variable at t+dt
                    tendency::LowerTriangularMatrix{Complex{NF}},   # tendency (dynamics+physics) of A
                    dt::Real,                                       # time step (=2Δt, but for init steps =Δt,Δt/2)
                    lf::Int,                                        # leapfrog index to dis/enable William's filter
                    L::Leapfrog{NF},                                # struct with constants
                    ) where {NF<:AbstractFloat}                     # number format NF

    @boundscheck lf == 1 || lf == 2 || throw(BoundsError())         # index lf picks leapfrog dim
    
    A_lf = lf == 1 ? A_old : A_new                      # view on either t or t+dt to dis/enable William's filter        
    (;robert_filter, william_filter) = L                # coefficients for the Robert and William's filter
    two = convert(NF,2)                                 # 2 in number format NF
    dt_NF = convert(NF,dt)                              # time step dt in number format NF

    # LEAP FROG time step with or without Robert+William's filter
    # Robert time filter to compress computational mode, Williams' filter for 3rd order accuracy
    # see William (2009), Eq. 7-9
    # for lf == 1 (initial time step) no filter applied (w1=w2=0)
    # for lf == 2 (later steps) Robert+William's filter is applied
    w1 = lf == 1 ? zero(NF) : robert_filter*william_filter/two         # = ν*α/2 in William (2009, Eq. 8)
    w2 = lf == 1 ? zero(NF) : robert_filter*(1-william_filter)/two     # = ν(1-α)/2 in William (2009, Eq. 9)

    @inbounds for lm in eachharmonic(A_old,A_new,A_lf,tendency)
        a_old = A_old[lm]                       # double filtered value from previous time step (t-Δt)
        a_new = a_old + dt_NF*tendency[lm]      # Leapfrog/Euler step depending on dt=Δt,2Δt (unfiltered at t+Δt)
        a_update = a_old - two*A_lf[lm] + a_new # Eq. 8&9 in William (2009), calculate only once
        A_old[lm] = A_lf[lm] + w1*a_update      # Robert's filter: A_old[lm] becomes 2xfiltered value at t
        A_new[lm] = a_new - w2*a_update         # Williams' filter: A_new[lm] becomes 1xfiltred value at t+Δt
    end
end

# variables that are leapfrogged in the respective models that are on layers (so excl surface pressure)
leapfrog_layer_vars(::Barotropic) = (:vor,)
leapfrog_layer_vars(::ShallowWater) = (:vor, :div)
leapfrog_layer_vars(::PrimitiveDry) = (:vor, :div, :temp)
leapfrog_layer_vars(::PrimitiveWet) = (:vor, :div, :temp, :humid)

function leapfrog!( progn::PrognosticLayerTimesteps,
                    diagn::DiagnosticVariablesLayer,
                    dt::Real,               # time step (mostly =2Δt, but for init steps =Δt,Δt/2)
                    lf::Int,                # leapfrog index to dis/enable William's filter
                    model::ModelSetup)
               
    for var in leapfrog_layer_vars(model)
        var_old = getproperty(progn.timesteps[1],var)
        var_new = getproperty(progn.timesteps[2],var)
        var_tend = getproperty(diagn.tendencies,Symbol(var,:_tend))
        leapfrog!(var_old,var_new,var_tend,dt,lf,model.time_stepping)
    end
end

"""
    first_timesteps!(   progn::PrognosticVariables, # all prognostic variables
                        diagn::DiagnosticVariables, # all pre-allocated diagnostic variables
                        time::DateTime,             # time at timestep
                        M::ModelSetup,              # everything that is constant at runtime
                        feedback::AbstractFeedback  # feedback struct
                        )

Performs the first two initial time steps (Euler forward, unfiltered leapfrog) to populate the
prognostic variables with two time steps (t=0,Δt) that can then be used in the normal leap frogging."""
function first_timesteps!(  progn::PrognosticVariables, # all prognostic variables
                            diagn::DiagnosticVariables, # all pre-allocated diagnostic variables
                            time::DateTime,             # time at timestep
                            model::ModelSetup,          # everything that is constant at runtime
                            feedback::AbstractFeedback, # feedback struct
                            outputter::AbstractOutput)
    
    (; n_timesteps, Δt, Δt_sec ) = model.constants
    n_timesteps == 0 && return time     # exit immediately for no time steps

    (;implicit) = model

    # FIRST TIME STEP (EULER FORWARD with dt=Δt/2)
    i = 1                               # time step index
    lf1 = 1                             # without Robert+William's filter
    lf2 = 1                             # evaluates all tendencies at t=0,
                                        # the first leapfrog index (=>Euler forward)
    temperature_profile!(diagn,progn,model,lf2) # used for implicit solver, update occasionally
    initialize!(model,diagn,Δt/2)      # update precomputed implicit terms with time step Δt/2
    timestep!(progn,diagn,time,Δt/2,i,model,lf1,lf2)
    time += Dates.Second(Δt_sec÷2)      # update by half the leapfrog time step Δt used here
    progress!(feedback,progn)

    # SECOND TIME STEP (UNFILTERED LEAPFROG with dt=Δt, leapfrogging from t=0 over t=Δt/2 to t=Δt)
    initialize!(model,diagn,Δt)    # update precomputed implicit terms with time step Δt
    lf1 = 1                             # without Robert+William's filter
    lf2 = 2                             # evaluate all tendencies at t=dt/2,
                                        # the 2nd leapfrog index (=>Leapfrog)
    timestep!(progn,diagn,time,Δt,i,model,lf1,lf2)
    time += Dates.Second(Δt_sec÷2)      # now 2nd leapfrog step is at t=Δt
    progress!(feedback,progn)
    write_netcdf_output!(outputter,time,diagn,model)

    return time
end

"""
    timestep!(  progn::PrognosticVariables,     # all prognostic variables
                diagn::DiagnosticVariables,     # all pre-allocated diagnostic variables
                time::DateTime,                 # time at timestep
                dt::Real,                       # time step (mostly =2Δt, but for init steps =Δt,Δt/2)
                lf1::Int=2,                     # leapfrog index 1 (dis/enables Robert+William's filter)
                lf2::Int=2,                     # leapfrog index 2 (time step used for tendencies)
                M::BarotropicModel,             # everything that's constant at runtime
                )

Calculate a single time step for the barotropic vorticity equation model of SpeedyWeather.jl """
function timestep!( progn::PrognosticVariables,     # all prognostic variables
                    diagn::DiagnosticVariables,     # all pre-allocated diagnostic variables
                    time::DateTime,                 # time at time step 
                    dt::Real,                       # time step (mostly =2Δt, but for init steps =Δt,Δt/2)
                    i::Integer,                     # time step index
                    model::Barotropic,              # everything that's constant at runtime
                    lf1::Int=2,                     # leapfrog index 1 (dis/enables Robert+William's filter)
                    lf2::Int=2,                     # leapfrog index 2 (time step used for tendencies)
                    )

    (;horizontal_diffusion, time_stepping) = model

    # LOOP OVER LAYERS FOR TENDENCIES, DIFFUSION, LEAPFROGGING AND PROPAGATE STATE TO GRID
    for (progn_layer,diagn_layer) in zip(progn.layers,diagn.layers)
        dynamics_tendencies!(diagn_layer,model)
        horizontal_diffusion!(progn_layer,diagn_layer,horizontal_diffusion)
        leapfrog!(progn_layer,diagn_layer,dt,lf1,time_stepping)
        gridded!(diagn_layer,progn_layer,lf2,model)
    end
end

"""
    timestep!(  progn::PrognosticVariables{NF}, # all prognostic variables
                diagn::DiagnosticVariables{NF}, # all pre-allocated diagnostic variables
                time::DateTime,                 # time at timestep
                dt::Real,                       # time step (mostly =2Δt, but for init steps =Δt,Δt/2)
                M::ShallowWaterModel,           # everything that's constant at runtime
                lf1::Int=2,                     # leapfrog index 1 (dis/enables Robert+William's filter)
                lf2::Int=2                      # leapfrog index 2 (time step used for tendencies)
                ) where {NF<:AbstractFloat}

Calculate a single time step for the shallow water model of SpeedyWeather.jl """
function timestep!( progn::PrognosticVariables{NF}, # all prognostic variables
                    diagn::DiagnosticVariables{NF}, # all pre-allocated diagnostic variables
                    time::DateTime,                 # time at timestep
                    dt::Real,                       # time step (mostly =2Δt, but for init steps =Δt,Δt/2)
                    i::Integer,                     # time step index
                    model::ShallowWater,            # everything that's constant at runtime
                    lf1::Int=2,                     # leapfrog index 1 (dis/enables Robert+William's filter)
                    lf2::Int=2                      # leapfrog index 2 (time step used for tendencies)
                    ) where {NF<:AbstractFloat}

    progn_layer = progn.layers[1]                   # only calculate tendencies for the first layer
    diagn_layer = diagn.layers[1]
    diagn_surface = diagn.surface
    progn_surface = progn.surface
    (;pres) = progn.surface.timesteps[lf2]
    (;implicit, horizontal_diffusion, time_stepping, spectral_transform) = model

    # zero_tendencies!(diagn)
    
    # GET TENDENCIES, CORRECT THEM FOR SEMI-IMPLICIT INTEGRATION
    # forcing!(diagn_layer,diagn_surface,time,model.forcing)
    dynamics_tendencies!(diagn_layer,diagn_surface,pres,time,model)
    implicit_correction!(diagn_layer,progn_layer,diagn_surface,progn_surface,implicit)
    
    # APPLY DIFFUSION, STEP FORWARD IN TIME, AND TRANSFORM NEW TIME STEP TO GRID
    horizontal_diffusion!(progn_layer,diagn_layer,horizontal_diffusion)
    leapfrog!(progn_layer,diagn_layer,dt,lf1,time_stepping)
    gridded!(diagn_layer,progn_layer,lf2,model)

    # SURFACE LAYER (pressure), no diffusion though
    (;pres_grid,pres_tend) = diagn.surface
    pres_old = progn.surface.timesteps[1].pres
    pres_new = progn.surface.timesteps[2].pres
    leapfrog!(pres_old,pres_new,pres_tend,dt,lf1,time_stepping)
    gridded!(pres_grid,pres,spectral_transform)
end

"""
    timestep!(  progn::PrognosticVariables{NF}, # all prognostic variables
                diagn::DiagnosticVariables{NF}, # all pre-allocated diagnostic variables
                time::DateTime,                 # time at timestep
                dt::Real,                       # time step (mostly =2Δt, but for init steps =Δt,Δt/2)
                M::PrimitiveEquation,           # everything that's constant at runtime
                lf1::Int=2,                     # leapfrog index 1 (dis/enables Robert+William's filter)
                lf2::Int=2                      # leapfrog index 2 (time step used for tendencies)
                ) where {NF<:AbstractFloat}

Calculate a single time step for the primitive equation model of SpeedyWeather.jl """
function timestep!( progn::PrognosticVariables{NF}, # all prognostic variables
                    diagn::DiagnosticVariables{NF}, # all pre-allocated diagnostic variables
                    time::DateTime,                 # time at timestep
                    dt::Real,                       # time step (mostly =2Δt, but for init steps =Δt,Δt/2)
                    i::Integer,                     # time step index
                    model::PrimitiveEquation,       # everything that's constant at runtime
                    lf1::Int=2,                     # leapfrog index 1 (dis/enables Robert+William's filter)
                    lf2::Int=2                      # leapfrog index 2 (time step used for tendencies)
                    ) where {NF<:AbstractFloat}

    # switch on/off all physics
    (;physics) = model.parameters
    physics && parameterization_tendencies!(diagn,time,model)
    physics || zero_tendencies!(diagn)              # set tendencies to zero otherwise

    # occasionally reinitialize the implicit solver with new temperature profile
    initialize_implicit!(model,diagn,progn,dt,i,lf2)

    dynamics_tendencies!(diagn,progn,model,lf2)     # dynamical core
    implicit_correction!(diagn,progn,model)         # semi-implicit time stepping corrections

    # LOOP OVER ALL LAYERS for diffusion, leapfrog time integration
    # and progn state from spectral to grid for next time step
    @floop for k in 1:diagn.nlev+1
        if k <= diagn.nlev                  # model levels
            diagn_layer = diagn.layers[k]
            progn_layer = progn.layers[k]

            horizontal_diffusion!(progn_layer,diagn_layer,model)    # implicit diffusion of vor, div, temp
            leapfrog!(progn_layer,diagn_layer,dt,lf1,model)         # time step forward for vor, div, temp
            gridded!(diagn_layer,progn_layer,lf2,model)             # propagate spectral state to grid
        else                                                        # surface level
            (;pres_grid,pres_tend) = diagn.surface
            pres_old = progn.surface.timesteps[1].pres
            pres_new = progn.surface.timesteps[2].pres
            pres_lf = progn.surface.timesteps[lf2].pres
            leapfrog!(pres_old,pres_new,pres_tend,dt,lf1,model.time_stepping)
            gridded!(pres_grid,pres_lf,model.spectral_transform)
        end
    end
end

"""
    time_stepping!( progn::PrognosticVariables,     # all prognostic variables
                    diagn::DiagnosticVariables,     # all pre-allocated diagnostic variables
                    model::ModelSetup)              # all precalculated structs

Main time loop that that initialises output and feedback, loops over all time steps
and calls the output and feedback functions."""
function time_stepping!(progn::PrognosticVariables, # all prognostic variables
                        diagn::DiagnosticVariables, # all pre-allocated diagnostic variables
                        model::ModelSetup)          # all precalculated structs
    
    (; n_timesteps, Δt, Δt_sec ) = model.time_stepping
    time = model.time_stepping.startdate

    # SCALING: we use vorticity*radius,divergence*radius in the dynamical core
    scale!(progn,model.spectral_grid.radius)

    # OUTPUT INITIALISATION AND STORING INITIAL CONDITIONS + FEEDBACK
    # propagate spectral state to grid variables for initial condition output
    (;output,feedback) = model
    lf = 1                                  # use first leapfrog index
    gridded!(diagn,progn,lf,model)
    initialize!(output,diagn,model.geometry)
    initialize!(feedback,model.spectral_grid,model.time_stepping)

    # FIRST TIMESTEPS: EULER FORWARD THEN 1x LEAPFROG
    time = first_timesteps!(progn,diagn,time,model,feedback,outputter)
    initialize_implicit!(model,diagn,2Δt)   # from now on precomputed implicit terms with 2Δt

    # MAIN LOOP
    for i in 2:n_timesteps                  # start at 2 as first Δt in first_timesteps!
        timestep!(progn,diagn,time,2Δt,i,model)   # calculate tendencies and leapfrog forward
        time += Dates.Second(Δt_sec)        # time of lf=2 and diagn after timestep!

        progress!(feedback,progn)           # updates the progress meter bar
        write_output!(outputter,time,diagn,model)
    end

    unscale!(progn)                         # undo radius-scaling for vor,div from the dynamical core
    write_restart_file(time,progn,outputter)
    progress_finish!(feedback)              # finishes the progress meter bar

    return progn
end