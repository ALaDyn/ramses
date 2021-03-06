subroutine move_fine(ilevel)
  use amr_commons
  use pm_commons
  use mpi_mod
  implicit none
  integer::ilevel
  !----------------------------------------------------------------------
  ! Update particle position and time-centred velocity at level ilevel.
  ! If particle sits entirely in level ilevel, then use fine grid force
  ! for CIC interpolation. Otherwise, use coarse grid (ilevel-1) force.
  !----------------------------------------------------------------------
  integer::igrid,jgrid,ipart,jpart,next_part,ig,ip,npart1
  integer,dimension(1:nvector),save::ind_grid,ind_part,ind_grid_part
  character(LEN=80)::filename,fileloc
  character(LEN=5)::nchar

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

  filename='trajectory.dat'
  call title(myid,nchar)
  fileloc=TRIM(filename)//TRIM(nchar)
  open(25+myid, file = fileloc, status = 'unknown', access = 'append')

  ! Update particles position and velocity
  ig=0
  ip=0
  ! Loop over grids
  igrid=headl(myid,ilevel)
  do jgrid=1,numbl(myid,ilevel)
     npart1=numbp(igrid)  ! Number of particles in the grid
     if(npart1>0)then
        ig=ig+1
        ind_grid(ig)=igrid
        ipart=headp(igrid)
        ! Loop over particles
        do jpart=1,npart1
           ! Save next particle  <---- Very important !!!
           next_part=nextp(ipart)
           if(ig==0)then
              ig=1
              ind_grid(ig)=igrid
           end if
           ip=ip+1
           ind_part(ip)=ipart
           ind_grid_part(ip)=ig
           if(ip==nvector)then
              call move1(ind_grid,ind_part,ind_grid_part,ig,ip,ilevel)
              ip=0
              ig=0
           end if
           ipart=next_part  ! Go to next particle
        end do
        ! End loop over particles
     end if
     igrid=next(igrid)   ! Go to next grid
  end do
  ! End loop over grids
  if(ip>0)call move1(ind_grid,ind_part,ind_grid_part,ig,ip,ilevel)

  close(25+myid)

111 format('   Entering move_fine for level ',I2)

end subroutine move_fine
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine move_fine_static(ilevel)
  use amr_commons
  use pm_commons
  use mpi_mod
  implicit none
  integer::ilevel
  !----------------------------------------------------------------------
  ! Update particle position and time-centred velocity at level ilevel.
  ! If particle sits entirely in level ilevel, then use fine grid force
  ! for CIC interpolation. Otherwise, use coarse grid (ilevel-1) force.
  !----------------------------------------------------------------------
  integer::igrid,jgrid,ipart,jpart,next_part,ig,ip,npart1,npart2
  integer,dimension(1:nvector),save::ind_grid,ind_part,ind_grid_part

  if(numbtot(1,ilevel)==0)return
  if(verbose)write(*,111)ilevel

  ! Update particles position and velocity
  ig=0
  ip=0
  ! Loop over grids
  igrid=headl(myid,ilevel)
  do jgrid=1,numbl(myid,ilevel)
     npart1=numbp(igrid)  ! Number of particles in the grid
     npart2=0

     ! Count particles
     if(npart1>0)then
        ipart=headp(igrid)
        ! Loop over particles
        do jpart=1,npart1
           ! Save next particle   <--- Very important !!!
           next_part=nextp(ipart)
           if(star) then
              if ( (.not. static_DM .and. is_DM(typep(ipart))) .or. &
                   & (.not. static_stars .and. is_not_DM(typep(ipart)) )  ) then
                 ! FIXME: there should be a static_sink as well
                 ! FIXME: what about debris?
                 npart2=npart2+1
              endif
           else
              if(.not.static_DM) then
                 npart2=npart2+1
              endif
           endif
           ipart=next_part  ! Go to next particle
        end do
     endif

     ! Gather star particles
     if(npart2>0)then
        ig=ig+1
        ind_grid(ig)=igrid
        ipart=headp(igrid)
        ! Loop over particles
        do jpart=1,npart1
           ! Save next particle   <--- Very important !!!
           next_part=nextp(ipart)
           ! Select particles
           if(star) then
              if ( (.not. static_DM .and. is_DM(typep(ipart))) .or. &
                   & (.not. static_stars .and. is_not_DM(typep(ipart)) )  ) then
                 ! FIXME: there should be a static_sink as well
                 ! FIXME: what about debris?
                 if(ig==0)then
                    ig=1
                    ind_grid(ig)=igrid
                 end if
                 ip=ip+1
                 ind_part(ip)=ipart
                 ind_grid_part(ip)=ig
              endif
           else
              if(.not.static_dm) then
                 if(ig==0)then
                    ig=1
                    ind_grid(ig)=igrid
                 end if
                 ip=ip+1
                 ind_part(ip)=ipart
                 ind_grid_part(ip)=ig
              endif
           endif
           if(ip==nvector)then
              call move1(ind_grid,ind_part,ind_grid_part,ig,ip,ilevel)
              ip=0
              ig=0
           end if
           ipart=next_part  ! Go to next particle
        end do
        ! End loop over particles
     end if
     igrid=next(igrid)   ! Go to next grid
  end do
  ! End loop over grids
  if(ip>0)call move1(ind_grid,ind_part,ind_grid_part,ig,ip,ilevel)

111 format('   Entering move_fine for level ',I2)

end subroutine move_fine_static
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine move1(ind_grid,ind_part,ind_grid_part,ng,np,ilevel)
  use amr_commons
  use pm_commons
  use poisson_commons
  use hydro_commons, ONLY: uold,unew,smallr,nvar,gamma
  implicit none
  integer::ng,np,ilevel
  integer,dimension(1:nvector)::ind_grid
  integer,dimension(1:nvector)::ind_grid_part,ind_part
  !------------------------------------------------------------
  ! This routine computes the force on each particle by
  ! inverse CIC and computes new positions for all particles.
  ! If particle sits entirely in fine level, then CIC is performed
  ! at level ilevel. Otherwise, it is performed at level ilevel-1.
  ! This routine is called by move_fine.
  !------------------------------------------------------------
  logical::error
  integer::i,j,ind,idim,nx_loc,isink,index_part,ivar_dust
  real(dp)::dx,dx_loc,scale,vol_loc
  real(dp)::ctm! ERM: re mend 1.15D3
  real(dp)::ts !ERM: recommend 2.2D-1
  real(dp)::rd ! ERM: Grain size parameter

  ! Grid-based arrays
  integer ,dimension(1:nvector),save::father_cell
  real(dp),dimension(1:nvector,1:ndim),save::x0
  integer ,dimension(1:nvector,1:threetondim),save::nbors_father_cells
  integer ,dimension(1:nvector,1:twotondim),save::nbors_father_grids
  ! Particle-based arrays
  logical ,dimension(1:nvector),save::ok
  real(dp),dimension(1:nvector,1:ndim),save::x,ff,new_xp,new_vp,dd,dg,vcom,ucorr !Corrected fluid velocity to use later. Interpolated...
  real(dp),dimension(1:nvector,1:ndim),save::uu,bb,vv
  real(dp),dimension(1:nvector),save:: dgr,tss,mov ! ERM: fluid density interpolated to grain pos. and stopping times
  integer ,dimension(1:nvector,1:ndim),save::ig,id,igg,igd,icg,icd
  real(dp),dimension(1:nvector,1:twotondim),save::vol
  integer ,dimension(1:nvector,1:twotondim),save::igrid,icell,indp,kg
  real(dp),dimension(1:3)::skip_loc
  real(dp)::den_dust,den_gas,mom_dust,mom_gas,velocity_com

  ctm = charge_to_mass
  rd = sqrt(gamma)*0.62665706865775*grain_size !constant for epstein drag law.
  ts = t_stop!  ERM: Not used if constant_t_stop==.false.

  ! Mesh spacing in that level
  dx=0.5D0**ilevel
  nx_loc=(icoarse_max-icoarse_min+1)
  skip_loc=(/0.0d0,0.0d0,0.0d0/)
  if(ndim>0)skip_loc(1)=dble(icoarse_min)
  if(ndim>1)skip_loc(2)=dble(jcoarse_min)
  if(ndim>2)skip_loc(3)=dble(kcoarse_min)
  scale=boxlen/dble(nx_loc)
  dx_loc=dx*scale
  vol_loc=dx_loc**3

  ! Lower left corner of 3x3x3 grid-cube
  do idim=1,ndim
     do i=1,ng
        x0(i,idim)=xg(ind_grid(i),idim)-3.0D0*dx
     end do
  end do

  ! Gather neighboring father cells (should be present anytime !)
  do i=1,ng
     father_cell(i)=father(ind_grid(i))
  end do
  call get3cubefather(father_cell,nbors_father_cells,nbors_father_grids,&
       & ng,ilevel)

  ! Rescale particle position at level ilevel
  do idim=1,ndim
     do j=1,np
        x(j,idim)=xp(ind_part(j),idim)/scale+skip_loc(idim)
     end do
  end do
  do idim=1,ndim
     do j=1,np
        x(j,idim)=x(j,idim)-x0(ind_grid_part(j),idim)
     end do
  end do
  do idim=1,ndim
     do j=1,np
        x(j,idim)=x(j,idim)/dx
     end do
  end do

  ! Check for illegal moves
  error=.false.
  do idim=1,ndim
     do j=1,np
        if(x(j,idim)<0.5D0.or.x(j,idim)>5.5D0)error=.true.
     end do
  end do
  if(error)then
     write(*,*)'problem in move'
     do idim=1,ndim
        do j=1,np
           if(x(j,idim)<0.5D0.or.x(j,idim)>5.5D0)then
              write(*,*)x(j,1:ndim)
           endif
        end do
     end do
     stop
  end if

  ! CIC at level ilevel (dd: right cloud boundary; dg: left cloud boundary)
  do idim=1,ndim
     do j=1,np
        dd(j,idim)=x(j,idim)+0.5D0
        id(j,idim)=int(dd(j,idim))
        dd(j,idim)=dd(j,idim)-id(j,idim)
        dg(j,idim)=1.0D0-dd(j,idim)
        ig(j,idim)=id(j,idim)-1
     end do
  end do

   ! Compute parent grids
  do idim=1,ndim
     do j=1,np
        igg(j,idim)=ig(j,idim)/2
        igd(j,idim)=id(j,idim)/2
     end do
  end do
#if NDIM==1
  do j=1,np
     kg(j,1)=1+igg(j,1)
     kg(j,2)=1+igd(j,1)
  end do
#endif
#if NDIM==2
  do j=1,np
     kg(j,1)=1+igg(j,1)+3*igg(j,2)
     kg(j,2)=1+igd(j,1)+3*igg(j,2)
     kg(j,3)=1+igg(j,1)+3*igd(j,2)
     kg(j,4)=1+igd(j,1)+3*igd(j,2)
  end do
#endif
#if NDIM==3
  do j=1,np
     kg(j,1)=1+igg(j,1)+3*igg(j,2)+9*igg(j,3)
     kg(j,2)=1+igd(j,1)+3*igg(j,2)+9*igg(j,3)
     kg(j,3)=1+igg(j,1)+3*igd(j,2)+9*igg(j,3)
     kg(j,4)=1+igd(j,1)+3*igd(j,2)+9*igg(j,3)
     kg(j,5)=1+igg(j,1)+3*igg(j,2)+9*igd(j,3)
     kg(j,6)=1+igd(j,1)+3*igg(j,2)+9*igd(j,3)
     kg(j,7)=1+igg(j,1)+3*igd(j,2)+9*igd(j,3)
     kg(j,8)=1+igd(j,1)+3*igd(j,2)+9*igd(j,3)
  end do
#endif
  do ind=1,twotondim
     do j=1,np
        igrid(j,ind)=son(nbors_father_cells(ind_grid_part(j),kg(j,ind)))
     end do
  end do

  ! Check if particles are entirely in level ilevel
  ok(1:np)=.true.
  do ind=1,twotondim
     do j=1,np
        ok(j)=ok(j).and.igrid(j,ind)>0
     end do
  end do

  ! If not, rescale position at level ilevel-1
  do idim=1,ndim
     do j=1,np
        if(.not.ok(j))then
           x(j,idim)=x(j,idim)/2.0D0
        end if
     end do
  end do
  ! If not, redo CIC at level ilevel-1
  do idim=1,ndim
     do j=1,np
        if(.not.ok(j))then
           dd(j,idim)=x(j,idim)+0.5D0
           id(j,idim)=int(dd(j,idim))
           dd(j,idim)=dd(j,idim)-id(j,idim)
           dg(j,idim)=1.0D0-dd(j,idim)
           ig(j,idim)=id(j,idim)-1
        end if
     end do
  end do

 ! Compute parent cell position
  do idim=1,ndim
     do j=1,np
        if(ok(j))then
           icg(j,idim)=ig(j,idim)-2*igg(j,idim)
           icd(j,idim)=id(j,idim)-2*igd(j,idim)
        else
           icg(j,idim)=ig(j,idim)
           icd(j,idim)=id(j,idim)
        end if
     end do
  end do
#if NDIM==1
  do j=1,np
     icell(j,1)=1+icg(j,1)
     icell(j,2)=1+icd(j,1)
  end do
#endif
#if NDIM==2
  do j=1,np
     if(ok(j))then
        icell(j,1)=1+icg(j,1)+2*icg(j,2)
        icell(j,2)=1+icd(j,1)+2*icg(j,2)
        icell(j,3)=1+icg(j,1)+2*icd(j,2)
        icell(j,4)=1+icd(j,1)+2*icd(j,2)
     else
        icell(j,1)=1+icg(j,1)+3*icg(j,2)
        icell(j,2)=1+icd(j,1)+3*icg(j,2)
        icell(j,3)=1+icg(j,1)+3*icd(j,2)
        icell(j,4)=1+icd(j,1)+3*icd(j,2)
     end if
  end do
#endif
#if NDIM==3
  do j=1,np
     if(ok(j))then
        icell(j,1)=1+icg(j,1)+2*icg(j,2)+4*icg(j,3)
        icell(j,2)=1+icd(j,1)+2*icg(j,2)+4*icg(j,3)
        icell(j,3)=1+icg(j,1)+2*icd(j,2)+4*icg(j,3)
        icell(j,4)=1+icd(j,1)+2*icd(j,2)+4*icg(j,3)
        icell(j,5)=1+icg(j,1)+2*icg(j,2)+4*icd(j,3)
        icell(j,6)=1+icd(j,1)+2*icg(j,2)+4*icd(j,3)
        icell(j,7)=1+icg(j,1)+2*icd(j,2)+4*icd(j,3)
        icell(j,8)=1+icd(j,1)+2*icd(j,2)+4*icd(j,3)
     else
        icell(j,1)=1+icg(j,1)+3*icg(j,2)+9*icg(j,3)
        icell(j,2)=1+icd(j,1)+3*icg(j,2)+9*icg(j,3)
        icell(j,3)=1+icg(j,1)+3*icd(j,2)+9*icg(j,3)
        icell(j,4)=1+icd(j,1)+3*icd(j,2)+9*icg(j,3)
        icell(j,5)=1+icg(j,1)+3*icg(j,2)+9*icd(j,3)
        icell(j,6)=1+icd(j,1)+3*icg(j,2)+9*icd(j,3)
        icell(j,7)=1+icg(j,1)+3*icd(j,2)+9*icd(j,3)
        icell(j,8)=1+icd(j,1)+3*icd(j,2)+9*icd(j,3)
     end if
  end do
#endif

  ! Compute parent cell adresses
  do ind=1,twotondim
     do j=1,np
        if(ok(j))then
           indp(j,ind)=ncoarse+(icell(j,ind)-1)*ngridmax+igrid(j,ind)
        else
           indp(j,ind)=nbors_father_cells(ind_grid_part(j),icell(j,ind))
        end if
     end do
  end do

  ! Compute cloud volumes
#if NDIM==1
  do j=1,np
     vol(j,1)=dg(j,1)
     vol(j,2)=dd(j,1)
  end do
#endif
#if NDIM==2
  do j=1,np
     vol(j,1)=dg(j,1)*dg(j,2)
     vol(j,2)=dd(j,1)*dg(j,2)
     vol(j,3)=dg(j,1)*dd(j,2)
     vol(j,4)=dd(j,1)*dd(j,2)
  end do
#endif
#if NDIM==3
  do j=1,np
     vol(j,1)=dg(j,1)*dg(j,2)*dg(j,3)
     vol(j,2)=dd(j,1)*dg(j,2)*dg(j,3)
     vol(j,3)=dg(j,1)*dd(j,2)*dg(j,3)
     vol(j,4)=dd(j,1)*dd(j,2)*dg(j,3)
     vol(j,5)=dg(j,1)*dg(j,2)*dd(j,3)
     vol(j,6)=dd(j,1)*dg(j,2)*dd(j,3)
     vol(j,7)=dg(j,1)*dd(j,2)*dd(j,3)
     vol(j,8)=dd(j,1)*dd(j,2)*dd(j,3)
  end do
#endif

  ! Various fields interpolated to particle positions
  ! Gather 3-velocity and 3-magnetic field
  uu(1:np,1:ndim)=0.0D0
  bb(1:np,1:ndim)=0.0D0
  if(boris.and.hydro)then
     do ind=1,twotondim
        do idim=1,ndim
           do j=1,np
              uu(j,idim)=uu(j,idim)+uold(indp(j,ind),idim+1)/max(uold(indp(j,ind),1),smallr)*vol(j,ind)
              bb(j,idim)=bb(j,idim)+0.5D0*(uold(indp(j,ind),idim+5)+uold(indp(j,ind),idim+nvar))*vol(j,ind)
           end do
        end do
     end do
  endif

  ! Gather center of mass 3-velocity
  ivar_dust=9
  if(nvar<ivar_dust+ndim)then
     write(*,*)'You need to compile ramses with nvar=',ivar_dust+ndim
     stop
  endif
  vcom(1:np,1:ndim)=0.0D0 ! Will probably want to break things off and do them separately....
  if(boris.and.hydro)then
     do ind=1,twotondim
        do idim=1,ndim
           do j=1,np
              den_gas=uold(indp(j,ind),1)
              mom_gas=uold(indp(j,ind),1+idim)
              den_dust=uold(indp(j,ind),ivar_dust)
              mom_dust=uold(indp(j,ind),ivar_dust+idim)
              velocity_com=(mom_gas*(1.0d0+dtnew(ilevel)/ts)+mom_dust*dtnew(ilevel)/ts)/(den_gas*(1.0d0+dtnew(ilevel)/ts)+den_dust*dtnew(ilevel)/ts)
              vcom(j,idim)=vcom(j,idim)+velocity_com*vol(j,ind)
!              write(*,*)idim,vcom(j,idim),den_gas,mom_gas,den_dust,mom_dust
           end do
        end do
     end do
  endif

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  ! ERM: Block here is temporary
 dgr(1:np) = 0.0D0
  if(boris)then
     do ind=1,twotondim
         do j=1,np
            dgr(j)=dgr(j)+uold(indp(j,ind),1)*vol(j,ind)
        end do
     end do
  endif

  if(boris)then
    do j=1,np
        mov(j) = mp(ind_part(j))/vol_loc
    end do
  endif

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

  ! Gather 3-velocity
  ff(1:np,1:ndim)=0.0D0
  if(tracer.and.hydro)then
     do ind=1,twotondim
        do idim=1,ndim
           do j=1,np
              ff(j,idim)=ff(j,idim)+uold(indp(j,ind),idim+1)/max(uold(indp(j,ind),1),smallr)*vol(j,ind)
           end do
        end do
     end do
  endif
  ! Gather 3-force
  if(poisson)then
     do ind=1,twotondim
        do idim=1,ndim
           do j=1,np
              ff(j,idim)=ff(j,idim)+f(indp(j,ind),idim)*vol(j,ind)
           end do
        end do
#ifdef OUTPUT_PARTICLE_POTENTIAL
        do j=1,np
           ptcl_phi(ind_part(j)) = phi(indp(j,ind))
        end do
#endif
     end do
  endif

  ! Update velocity
  do idim=1,ndim
     if(static.or.tracer)then
        do j=1,np
           new_vp(j,idim)=ff(j,idim)
        end do
     else
        do j=1,np
           new_vp(j,idim)=vp(ind_part(j),idim)+ff(j,idim)*0.5D0*dtnew(ilevel)
        end do
     endif
  end do

  ! Full EM kick
  if(boris.and.hydro)then
     vv(1:np,1:ndim)=new_vp(1:np,1:ndim)
     call FullEMKick(solver_type,np,dtnew(ilevel),ctm,bb,uu,vv,mov,dgr)
     new_vp(1:np,1:ndim)=vv(1:np,1:ndim)
  endif

  ! Drag kick
  if(boris.and.hydro)then
     ! Update velocity
     vv(1:np,1:ndim)=new_vp(1:np,1:ndim)
     do idim=1,ndim
        do j=1,np
           new_vp(j,idim)=(vv(j,idim)+vcom(j,idim)*dtnew(ilevel)/ts)/(1.0d0+dtnew(ilevel)/ts)
!           write(*,*)idim,vcom(j,idim),new_vp(j,idim)
        end do
     end do
  endif

!!$  if((boris.and.hydro).and.constant_t_stop)then
!!$     vv(1:np,1:ndim)=new_vp(1:np,1:ndim) ! ERM: Set the value of vv.
!!$     call FirstAndSecondBorisKick(np,dtnew(ilevel),ctm,ts,bb,uu,vv)
!!$     new_vp(1:np,1:ndim)=vv(1:np,1:ndim)
!!$  endif
!!$
!!$  if((boris.and.hydro).and.(.not.constant_t_stop))then
!!$    vv(1:np,1:ndim)=new_vp(1:np,1:ndim) ! ERM: Set the value of vv.
!!$    ! ERM: Compute the stopping time assuming a constant (and unit) sound speed
!!$    if(.not.constant_t_stop.and.boris)then
!!$      do j=1,np
!!$        tss(j)=rd/(dgr(j)*&
!!$        sqrt(1.0+0.2209*gamma*&
!!$        ((vv(j,1)-uu(j,1))**2+(vv(j,2)-uu(j,2))**2+(vv(j,3)-uu(j,3))**2)))
!!$      end do
!!$    endif
!!$    call FirstAndSecondBorisKickWithVarTs(np,dtnew(ilevel),ctm,tss,bb,uu,vv)
!!$    new_vp(1:np,1:ndim)=vv(1:np,1:ndim)
!!$  endif

  ! For sink cloud particle only
  if(sink)then
     ! Overwrite cloud particle velocity with sink velocity
     do idim=1,ndim
        do j=1,np
           if( is_cloud(typep(ind_part(j))) ) then
              isink=-idp(ind_part(j))
              new_vp(j,idim)=vsnew(isink,idim,ilevel)
           end if
        end do
     end do
  end if

  ! Output data to trajectory file
  if((boris.or.tracer).and.constant_t_stop)then
     do index_part=1,10
        do j=1,np
           if(idp(ind_part(j)).EQ.index_part)then
              write(25+myid,*)t-dtnew(ilevel),idp(ind_part(j)),& ! Old time
                   & xp(ind_part(j),1),xp(ind_part(j),2),xp(ind_part(j),3),& ! Old particle position
                   & vp(ind_part(j),1),vp(ind_part(j),2),vp(ind_part(j),3),& ! Old particle velocity
                   &  uu(j,1),uu(j,2),uu(j,3),& ! Old fluid velocity
                   &  bb(j,1),bb(j,2),bb(j,3),& ! Old magnetic field.
                   & new_vp(j,1),new_vp(j,2),new_vp(j,3) ! NEW particle velocity (for comparison)
           end if
        end do
     end do
  endif

  if((boris.or.tracer).and.(.not.constant_t_stop))then
     do index_part=1,10
        do j=1,np
           if(idp(ind_part(j)).EQ.index_part)then
              write(25+myid,*)t,idp(ind_part(j)),xp(ind_part(j),1),xp(ind_part(j),2),xp(ind_part(j),3),&
              tss(j),& ! could have this as density instead
              vv(j,1),vv(j,2),vv(j,3),& ! Velocity itself.
              uu(j,1),uu(j,2),uu(j,3),& ! Fluid velocity itself.
              bb(j,1),bb(j,2),bb(j,3),& ! Magnetic field.
              uu(j,3)*bb(j,2)-uu(j,2)*bb(j,3),uu(j,1)*bb(j,3)-uu(j,3)*bb(j,2),uu(j,2)*bb(j,1)-uu(j,1)*bb(j,2) ! Electric field
           end if
        end do
     end do
  endif

  ! Store new velocity
  do idim=1,ndim
     do j=1,np
        vp(ind_part(j),idim)=new_vp(j,idim)
     end do
  end do

  ! Deposit minus final dust momentum to new gas momentum
  do ind=1,twotondim
     do idim=1,ndim
        do j=1,np
           if(ok(j))then
              unew(indp(j,ind),1+idim)=unew(indp(j,ind),1+idim)-mp(ind_part(j))*vp(ind_part(j),idim)*vol(j,ind)/vol_loc
           end if
        end do
     end do
  end do

  ! Update position
  do idim=1,ndim
     if(static)then
        do j=1,np
           new_xp(j,idim)=xp(ind_part(j),idim)
        end do
     else
        do j=1,np
           new_xp(j,idim)=xp(ind_part(j),idim)+new_vp(j,idim)*dtnew(ilevel)
        end do
     endif
  end do
  do idim=1,ndim
     do j=1,np
        xp(ind_part(j),idim)=new_xp(j,idim)
     end do
  end do

end subroutine move1
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine FirstAndSecondBorisKick_nodrag(nn,dt,ctm,b,u,v)
  ! The following subroutine will alter its last argument, v
  ! to be an intermediate step, having been either accelerated by
  ! drag+the electric field, or rotated by the magnetic field.
  use amr_parameters
  use hydro_parameters
  implicit none
  integer ::kick ! kick number
  integer ::nn ! number of cells
  real(dp) ::dt ! timestep
  real(dp) ::ctm ! charge-to-mass ratio
  real(dp),dimension(1:nvector,1:ndim) ::b ! magnetic field components
  real(dp),dimension(1:nvector,1:ndim) ::u ! fluid velocity
  real(dp),dimension(1:nvector,1:ndim) ::v ! grain velocity
  real(dp),dimension(1:nvector,1:ndim),save ::vo ! grain velocity "new"
  integer ::i ! Just an -index

  ! Magnetic kick
  do i=1,nn
     vo(i,1) = v(i,1) + (2*ctm*dt*( &
          &  - b(i,2)*( b(i,2)*ctm*dt*v(i,1)            ) &
          &  + b(i,2)*( b(i,1)*ctm*dt*v(i,2) - 2*v(i,3) ) &
          &  + b(i,3)*(-b(i,3)*ctm*dt*v(i,1) + 2*v(i,2) + b(i,1)*ctm*dt*v(i,3)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*ctm*dt*dt)
     vo(i,2) = v(i,2) + (2*ctm*dt*( &
          &  - b(i,3)*( b(i,3)*ctm*dt*v(i,2)            ) &
          &  + b(i,3)*( b(i,2)*ctm*dt*v(i,3) - 2*v(i,1) ) &
          &  + b(i,1)*(-b(i,1)*ctm*dt*v(i,2) + 2*v(i,3) + b(i,2)*ctm*dt*v(i,1)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*ctm*dt*dt)
     vo(i,3) = v(i,3) + (2*ctm*dt*( &
          &  - b(i,1)*( b(i,1)*ctm*dt*v(i,3)            ) &
          &  + b(i,1)*( b(i,3)*ctm*dt*v(i,1) - 2*v(i,2) ) &
          &  + b(i,2)*(-b(i,2)*ctm*dt*v(i,3) + 2*v(i,1) + b(i,3)*ctm*dt*v(i,2)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*ctm*dt*dt)
  end do
  v(1:nn,1:ndim)=vo(1:nn,1:ndim)

  ! First electric kick
  do i=1,nn
     vo(i,1) = v(i,1)-0.5*dt*ctm*(u(i,2)*b(i,3)-u(i,3)*b(i,2))
     vo(i,2) = v(i,2)-0.5*dt*ctm*(u(i,3)*b(i,1)-u(i,1)*b(i,3))
     vo(i,3) = v(i,3)-0.5*dt*ctm*(u(i,1)*b(i,2)-u(i,2)*b(i,1))
  end do
  v(1:nn,1:ndim)=vo(1:nn,1:ndim)

end subroutine FirstAndSecondBorisKick_nodrag

!#########################################################################
!#########################################################################
subroutine FullEMKick(com,nn,dt,ctm,b,u,v,mp,dgr)
  ! The following subroutine will alter its last argument, v
  ! to be an intermediate step, having been either accelerated by
  ! drag+the electric field, or rotated by the magnetic field.
  ! Also, mp is actually the particle mass over the cloud volume, here.
  use amr_parameters
  use hydro_parameters
  implicit none
  integer ::com ! solver_type
  integer ::kick ! kick number
  integer ::nn ! number of cells
  real(dp) ::dt ! timestep
  real(dp) ::ctm ! charge-to-mass ratio
  real(dp) ::ts ! stopping time
  real(dp),dimension(1:nn) ::mp,dgr
  real(dp),dimension(1:nvector,1:ndim) ::b ! magnetic field components
  real(dp),dimension(1:nvector,1:ndim) ::u ! fluid velocity
  real(dp),dimension(1:nvector,1:ndim) ::v ! grain velocity
  real(dp),dimension(1:nvector,1:ndim),save ::w,wo! grain velocity "new"
  integer ::i,idim ! Just an -index
  w(1:nn,1:ndim) = v(1:nn,1:ndim)-u(1:nn,1:ndim)
  do i=1,nn
     wo(i,1) = w(i,1) + (2*ctm*(1+com*mp(i)/dgr(i))*dt*( &
          &  - b(i,2)*( b(i,2)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,1)            ) &
          &  + b(i,2)*( b(i,1)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,2) - 2*w(i,3) ) &
          &  + b(i,3)*(-b(i,3)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,1) + 2*w(i,2) + b(i,1)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,3)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*(1+com*mp(i)/dgr(i))*ctm*(1+com*mp(i)/dgr(i))*dt*dt)
     wo(i,2) = w(i,2) + (2*ctm*(1+com*mp(i)/dgr(i))*dt*( &
          &  - b(i,3)*( b(i,3)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,2)            ) &
          &  + b(i,3)*( b(i,2)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,3) - 2*w(i,1) ) &
          &  + b(i,1)*(-b(i,1)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,2) + 2*w(i,3) + b(i,2)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,1)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*(1+com*mp(i)/dgr(i))*ctm*(1+com*mp(i)/dgr(i))*dt*dt)
     wo(i,3) = w(i,3) + (2*ctm*(1+com*mp(i)/dgr(i))*dt*( &
          &  - b(i,1)*( b(i,1)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,3)            ) &
          &  + b(i,1)*( b(i,3)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,1) - 2*w(i,2) ) &
          &  + b(i,2)*(-b(i,2)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,3) + 2*w(i,1) + b(i,3)*ctm*(1+com*mp(i)/dgr(i))*dt*w(i,2)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*(1+com*mp(i)/dgr(i))*ctm*(1+com*mp(i)/dgr(i))*dt*dt)
  end do

  do idim=1,ndim
    do i=1,nn
      v(i,idim)= (com*mp(i)*v(i,idim)+dgr(i)*u(i,idim))/(com*mp(i)+dgr(i)) +wo(i,idim)/(1+com*mp(i)/dgr(i))
    end do
  end do

end subroutine FullEMKick
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine FirstAndSecondBorisKick(nn,dt,ctm,ts,b,u,v)
  ! The following subroutine will alter its last argument, v
  ! to be an intermediate step, having been either accelerated by
  ! drag+the electric field, or rotated by the magnetic field.
  use amr_parameters
  use hydro_parameters
  implicit none
  integer ::kick ! kick number
  integer ::nn ! number of cells
  real(dp) ::dt ! timestep
  real(dp) ::ctm ! charge-to-mass ratio
  real(dp) ::ts ! stopping time
  real(dp),dimension(1:nvector,1:ndim) ::b ! magnetic field components
  real(dp),dimension(1:nvector,1:ndim) ::u ! fluid velocity
  real(dp),dimension(1:nvector,1:ndim) ::v ! grain velocity
  real(dp),dimension(1:nvector,1:ndim),save ::vo ! grain velocity "new"
  integer ::i ! Just an -index

  do i=1,nn
     vo(i,1) = v(i,1) + (2*ctm*dt*( &
          &  - b(i,2)*( b(i,2)*ctm*dt*v(i,1)            ) &
          &  + b(i,2)*( b(i,1)*ctm*dt*v(i,2) - 2*v(i,3) ) &
          &  + b(i,3)*(-b(i,3)*ctm*dt*v(i,1) + 2*v(i,2) + b(i,1)*ctm*dt*v(i,3)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*ctm*dt*dt)
     vo(i,2) = v(i,2) + (2*ctm*dt*( &
          &  - b(i,3)*( b(i,3)*ctm*dt*v(i,2)            ) &
          &  + b(i,3)*( b(i,2)*ctm*dt*v(i,3) - 2*v(i,1) ) &
          &  + b(i,1)*(-b(i,1)*ctm*dt*v(i,2) + 2*v(i,3) + b(i,2)*ctm*dt*v(i,1)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*ctm*dt*dt)
     vo(i,3) = v(i,3) + (2*ctm*dt*( &
          &  - b(i,1)*( b(i,1)*ctm*dt*v(i,3)            ) &
          &  + b(i,1)*( b(i,3)*ctm*dt*v(i,1) - 2*v(i,2) ) &
          &  + b(i,2)*(-b(i,2)*ctm*dt*v(i,3) + 2*v(i,1) + b(i,3)*ctm*dt*v(i,2)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*ctm*dt*dt)
  end do
  v(1:nn,1:ndim)=vo(1:nn,1:ndim)

  do i=1,nn
     vo(i,1) = (v(i,1)-0.5*dt*(ctm*(u(i,2)*b(i,3)-u(i,3)*b(i,2))-u(i,1)/ts))/(1.0+0.5*dt/ts)
     vo(i,2) = (v(i,2)-0.5*dt*(ctm*(u(i,3)*b(i,1)-u(i,1)*b(i,3))-u(i,2)/ts))/(1.0+0.5*dt/ts)
     vo(i,3) = (v(i,3)-0.5*dt*(ctm*(u(i,1)*b(i,2)-u(i,2)*b(i,1))-u(i,3)/ts))/(1.0+0.5*dt/ts)
  end do
  v(1:nn,1:ndim)=vo(1:nn,1:ndim)

end subroutine FirstAndSecondBorisKick
!#########################################################################
!#########################################################################
!#########################################################################
!#########################################################################
subroutine FirstAndSecondBorisKickWithVarTs(nn,dt,ctm,tss,b,u,v)
  ! The following subroutine will alter its last argument, v
  ! to be an intermediate step, having been either accelerated by
  ! drag+the electric field, or rotated by the magnetic field.
  use amr_parameters
  use hydro_parameters
  implicit none
  integer ::kick ! kick number
  integer ::nn ! number of cells
  real(dp) ::dt ! timestep
  real(dp) ::ctm ! charge-to-mass ratio
  real(dp),dimension(1:nvector) ::tss ! stopping time
  real(dp),dimension(1:nvector,1:ndim) ::b ! magnetic field components
  real(dp),dimension(1:nvector,1:ndim) ::u ! fluid velocity
  real(dp),dimension(1:nvector,1:ndim) ::v ! grain velocity
  real(dp),dimension(1:nvector,1:ndim),save ::vo ! grain velocity "new"
  integer ::i ! Just an -index

  do i=1,nn
     vo(i,1) = v(i,1) + (2*ctm*dt*( &
          &  - b(i,2)*( b(i,2)*ctm*dt*v(i,1)            ) &
          &  + b(i,2)*( b(i,1)*ctm*dt*v(i,2) - 2*v(i,3) ) &
          &  + b(i,3)*(-b(i,3)*ctm*dt*v(i,1) + 2*v(i,2) + b(i,1)*ctm*dt*v(i,3)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*ctm*dt*dt)
     vo(i,2) = v(i,2) + (2*ctm*dt*( &
          &  - b(i,3)*( b(i,3)*ctm*dt*v(i,2)            ) &
          &  + b(i,3)*( b(i,2)*ctm*dt*v(i,3) - 2*v(i,1) ) &
          &  + b(i,1)*(-b(i,1)*ctm*dt*v(i,2) + 2*v(i,3) + b(i,2)*ctm*dt*v(i,1)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*ctm*dt*dt)
     vo(i,3) = v(i,3) + (2*ctm*dt*( &
          &  - b(i,1)*( b(i,1)*ctm*dt*v(i,3)            ) &
          &  + b(i,1)*( b(i,3)*ctm*dt*v(i,1) - 2*v(i,2) ) &
          &  + b(i,2)*(-b(i,2)*ctm*dt*v(i,3) + 2*v(i,1) + b(i,3)*ctm*dt*v(i,2)) )) &
          &  / (4+(b(i,1)*b(i,1)+b(i,2)*b(i,2)+b(i,3)*b(i,3))*ctm*ctm*dt*dt)
  end do
  v(1:nn,1:ndim)=vo(1:nn,1:ndim)

  do i=1,nn
     vo(i,1) = (v(i,1)-0.5*dt*(ctm*(u(i,2)*b(i,3)-u(i,3)*b(i,2))-u(i,1)/tss(i)))/(1.0+0.5*dt/tss(i))
     vo(i,2) = (v(i,2)-0.5*dt*(ctm*(u(i,3)*b(i,1)-u(i,1)*b(i,3))-u(i,2)/tss(i)))/(1.0+0.5*dt/tss(i))
     vo(i,3) = (v(i,3)-0.5*dt*(ctm*(u(i,1)*b(i,2)-u(i,2)*b(i,1))-u(i,3)/tss(i)))/(1.0+0.5*dt/tss(i))
  end do
  v(1:nn,1:ndim)=vo(1:nn,1:ndim)

end subroutine FirstAndSecondBorisKickWithVarTs
