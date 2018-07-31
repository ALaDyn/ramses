module pm_parameters
  use amr_parameters, ONLY: dp
  integer::nsinkmax=2000            ! Maximum number of sinks
  integer::npartmax=0               ! Maximum number of particles
  integer::npart=0                  ! Actual number of particles
  integer::nsink=0                  ! Actual number of sinks
  integer::iseed=0                  ! Seed for stochastic star formation
  integer::nstar_tot=0              ! Total number of star particle
  real(dp)::mstar_tot=0             ! Total star mass
  real(dp)::mstar_lost=0            ! Missing star mass


  ! More sink related parameters, can all be set in namelist file

  integer::ir_cloud=4                        ! Radius of cloud region in unit of grid spacing (i.e. the ACCRETION RADIUS)
  integer::ir_cloud_massive=4                ! Radius of massive cloud region in unit of grid spacing for PM sinks
  real(dp)::sink_soft=2.d0                   ! Sink grav softening length in dx at levelmax for "direct force" sinks
  real(dp)::mass_sink_direct_force=-1.d0     ! mass above which sinks are treated as "direct force" objects

  logical::create_sinks=.false.              ! turn formation of new sinks on

  real(dp)::merging_timescale=-1.d0          ! time during which sinks are considered for merging (only when 'timescale' is used),
                                             ! used also as contraction timescale in creation
  real(dp)::cont_speed=0.                    ! Clump contraction rate

  character(LEN=15)::accretion_scheme='none' ! Sink accretion scheme; options: 'none', 'bondi'
  logical::bondi_accretion=.false.           ! NOT A NAMELIST PARAMETER
  logical::bondi_use_vrel=.true.             ! Use v_rel^2 in the denominator of Bondi formula

  real(dp)::mass_sink_seed=0.0               ! Initial sink mass
  real(dp)::mass_smbh_seed=0.0               ! Initial SMBH mass
  real(dp)::mass_merger_vel_check=-1.0       ! Threshold for velocity check in  merging; in Msun; default: don't check

  logical::eddington_limit=.false.           ! Switch for Eddington limit for the smbh case
  logical::clump_core=.false.                ! Trims the clump (for star formation)
  logical::verbose_AGN=.false.               ! Controls print verbosity for the SMBH case
  real(dp)::acc_sink_boost=1.0               ! Boost coefficient for accretion

  real(dp)::AGN_fbk_frac_ener=1.0            ! Fraction of AGN feedback released as thermal blast
  real(dp)::AGN_fbk_frac_mom=0.0             ! Fraction of AGN feedback released as momentum injection

  real(dp)::T2_min=1.d7                      ! Minimum temperature of the gas to trigger AGN blast; in K
  real(dp)::T2_max=1.d9                      ! Maximum allowed temperature of the AGN blast; in K
  real(dp)::T2_AGN=1.d12                     ! AGN blast temperature; in K

  real(dp)::cone_opening=180.                ! Outflow cone opening angle; in deg
  real(dp)::epsilon_kin=1.0                  ! Efficiency of kinetic feedback
  real(dp)::kin_mass_loading=100.            ! Mass loading of the jet
  real(dp)::AGN_fbk_mode_switch_threshold=0.01 ! M_Bondi/M_Edd ratio to switch between feedback modes
                                               ! if rate gt <value> is thermal, else is momentum; 
                                               ! if <value> le 0 then not active

  real(dp)::mass_halo_AGN=1.d10              ! Minimum mass of the halo for sink creation
  real(dp)::mass_clump_AGN=1.d10             ! Minimum mass of the clump for sink creation

  real(dp)::boost_threshold_density=0.1      ! Accretion boost threshold for Bondi

  real(dp)::max_mass_nsc=1.d15               ! Maximum mass of the Nuclear Star Cluster (msink) 

  type part_t
     ! We store these two things contiguously in memory
     ! because they are fetched at similar times
     integer(1) :: family
     integer(1) :: tag
  end type part_t

end module pm_parameters
