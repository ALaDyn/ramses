subroutine units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
  use amr_commons
  use hydro_commons
  use cooling_module
  real(dp)::scale_nH,scale_T2,scale_t,scale_v,scale_d,scale_l
  !-----------------------------------------------------------------------
  ! Conversion factors from user units into cgs units
  ! For gravity runs, make sure that G=1 in user units.
  !-----------------------------------------------------------------------

  ! scale_d converts mass density from user units into g/cc
  scale_d = 0.443201646421875d-17
  if(cosmo) scale_d = omega_m * rhoc *(h0/100.)**2 / aexp**3

  ! scale_t converts time from user units into seconds
  !1/(G*d0)**0.5
  scale_t = 0.183887441975074d+13
  if(cosmo) scale_t = aexp**2 / (h0*1d5/3.08d24)

  ! scale_l converts distance from user units into cm
  !25*32000 AU
  scale_l = 25*0.478712000000000d+18
  if(cosmo) scale_l = aexp * boxlen_ini * 3.08d24 / (h0/100)

  ! scale_v convert velocity in user units into cm/s
  scale_v = scale_l / scale_t

  ! scale_T2 converts (P/rho) in user unit into (T/mu) in Kelvin
  scale_T2 = mH/kB * scale_v**2

  ! scale_nH converts rho in user units into nH in H/cc
  scale_nH = 1./mH * scale_d

end subroutine units
