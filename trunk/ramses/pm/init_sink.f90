subroutine init_sink
  use amr_commons
  use pm_commons
  use clfind_commons
  implicit none
#ifndef WITHOUTMPI
  include 'mpif.h'
#endif
  real(dp)::scale_nH,scale_T2,scale_l,scale_d,scale_t,scale_v
  integer::idim
  integer::i,isink
  integer::ilun,nx_loc
  integer::nsinkold
  real(dp)::xx1,xx2,xx3,vv1,vv2,vv3,mm1,ll1,ll2,ll3
  real(dp),allocatable,dimension(:)::xdp
  integer,allocatable,dimension(:)::isp
  logical,allocatable,dimension(:)::nb
  logical::eof,ic_sink=.false.
  character(LEN=80)::filename
  character(LEN=80)::fileloc
  character(LEN=5)::nchar,ncharcpu

  integer,parameter::tag=1112,tag2=1113
  integer::dummy_io,info2



  !allocate all sink related quantities...
  allocate(weightp(1:npartmax,1:twotondim))
  weightp=0.0
  allocate(msink(1:nsinkmax))
  allocate(tsink(1:nsinkmax))
  allocate(idsink(1:nsinkmax))
  idsink=0 ! Important: need to set idsink to zero
  allocate(xsink(1:nsinkmax,1:ndim))
  allocate(vsink(1:nsinkmax,1:ndim))
  allocate(vsold(1:nsinkmax,1:ndim,levelmin:nlevelmax))
  allocate(vsnew(1:nsinkmax,1:ndim,levelmin:nlevelmax))
  allocate(fsink_partial(1:nsinkmax,1:ndim,levelmin:nlevelmax))
  allocate(fsink(1:nsinkmax,1:ndim))
  allocate(acc_rate(1:nsinkmax))
  acc_rate=0.
  allocate(acc_lum(1:nsinkmax))
  acc_lum=0.
  allocate(dt_acc(1:nsinkmax))
  allocate(rho_sink_tff(levelmin:nlevelmax))
  allocate(lsink(1:nsinkmax,1:3))
  lsink=0.d0
  allocate(level_sink(1:nsinkmax,levelmin:nlevelmax))
  allocate(delta_mass(1:nsinkmax))
  ! Temporary sink variables
  allocate(wden(1:nsinkmax))
  allocate(wmom(1:nsinkmax,1:ndim))
  allocate(weth(1:nsinkmax))
  allocate(wvol(1:nsinkmax))
  allocate(wdiv(1:nsinkmax))
  allocate(wden_new(1:nsinkmax))
  allocate(wmom_new(1:nsinkmax,1:ndim))
  allocate(weth_new(1:nsinkmax))
  allocate(wvol_new(1:nsinkmax))
  allocate(wdiv_new(1:nsinkmax))
  allocate(msink_new(1:nsinkmax))
  allocate(mseed(1:nsinkmax))
  allocate(mseed_new(1:nsinkmax))
  allocate(mseed_all(1:nsinkmax))
  allocate(msink_all(1:nsinkmax))
  allocate(tsink_new(1:nsinkmax))
  allocate(tsink_all(1:nsinkmax))
  allocate(idsink_new(1:nsinkmax))
  allocate(idsink_all(1:nsinkmax))
  allocate(idsink_old(1:nsinkmax))
  allocate(vsink_new(1:nsinkmax,1:ndim))
  allocate(vsink_all(1:nsinkmax,1:ndim))
  allocate(fsink_new(1:nsinkmax,1:ndim))
  allocate(fsink_all(1:nsinkmax,1:ndim))
  allocate(lsink_new(1:nsinkmax,1:3))
  allocate(lsink_all(1:nsinkmax,1:3))
  allocate(xsink_new(1:nsinkmax,1:ndim))
  allocate(xsink_all(1:nsinkmax,1:ndim))
  allocate(sink_jump(1:nsinkmax,1:ndim,levelmin:nlevelmax))
  sink_jump=0.d0
  allocate(level_sink_new(1:nsinkmax,levelmin:nlevelmax))
  allocate(dMsink_overdt(1:nsinkmax))
  allocate(dMBHoverdt(1:nsinkmax))
  allocate(eps_sink(1:nsinkmax))
  eps_sink=0.d0
  allocate(volume_gas(1:nsinkmax))
  volume_gas=0.d0
  allocate(vel_gas(1:nsinkmax,1:ndim))
  vel_gas=0.d0
  allocate(rho_gas(1:nsinkmax))
  rho_gas=0.d0
  allocate(c2sink(1:nsinkmax))
  allocate(weighted_density(1:nsinkmax,1:nlevelmax))
  weighted_density = 0.d0
  allocate(weighted_volume(1:nsinkmax,1:nlevelmax))
  weighted_volume = 0.d0
  allocate(weighted_ethermal(1:nsinkmax,1:nlevelmax))
  weighted_ethermal = 0.d0
  allocate(weighted_momentum(1:nsinkmax,1:nlevelmax,1:ndim))
  weighted_momentum = 0.d0
  allocate(weighted_divergence(1:nsinkmax,1:nlevelmax))
  weighted_divergence = 0.d0
  allocate(oksink_new(1:nsinkmax))
  allocate(oksink_all(1:nsinkmax))
  allocate(idsink_sort(1:nsinkmax))
  allocate(xmsink(1:nsinkmax))
  allocate(delta_mass_new(1:nsinkmax),delta_mass_all(1:nsinkmax))
  allocate(ok_blast_agn(1:nsinkmax),ok_blast_agn_all(1:nsinkmax))
  allocate(direct_force_sink(1:nsinkmax))
  allocate(new_born(1:nsinkmax),new_born_all(1:nsinkmax),new_born_new(1:nsinkmax))

  call units(scale_l,scale_t,scale_d,scale_v,scale_nH,scale_T2)
  ! Compute softening length from minimum cell spacing
  call compute_ncloud_sink  

  if(nrestart>0)then
     ilun=4*ncpu+myid+10
     call title(nrestart,nchar)

     if(IOGROUPSIZEREP>0)then
        call title(((myid-1)/IOGROUPSIZEREP)+1,ncharcpu)
        fileloc='output_'//TRIM(nchar)//'/group_'//TRIM(ncharcpu)//'/sink_'//TRIM(nchar)//'.out'
     else
        fileloc='output_'//TRIM(nchar)//'/sink_'//TRIM(nchar)//'.out'
     endif

     
     call title(myid,nchar)
     fileloc=TRIM(fileloc)//TRIM(nchar)

     ! Wait for the token                                                                                                                                                                    
#ifndef WITHOUTMPI
     if(IOGROUPSIZE>0) then
        if (mod(myid-1,IOGROUPSIZE)/=0) then
           call MPI_RECV(dummy_io,1,MPI_INTEGER,myid-1-1,tag,&
                & MPI_COMM_WORLD,MPI_STATUS_IGNORE,info2)
        end if
     endif
#endif

     open(unit=ilun,file=fileloc,form='unformatted')
     rewind(ilun)
     read(ilun)nsink
     read(ilun)nindsink

     if(nsink>0)then
        allocate(xdp(1:nsink))
        read(ilun)xdp ! Read sink mass
        msink(1:nsink)=xdp
        read(ilun)xdp ! Read sink birth epoch
        tsink(1:nsink)=xdp
        do idim=1,ndim
           read(ilun)xdp ! Read sink position
           xsink(1:nsink,idim)=xdp
        end do
        do idim=1,ndim
           read(ilun)xdp ! Read sink velocity
           vsink(1:nsink,idim)=xdp
        end do
        do idim=1,3
           read(ilun)xdp ! Read sink angular momentum
           lsink(1:nsink,idim)=xdp
        end do
        read(ilun)xdp ! Read sink accumulated rest mass energy
        delta_mass(1:nsink)=xdp
        read(ilun)xdp ! Read sink accretion rate
        acc_rate(1:nsink)=xdp
        deallocate(xdp)
        allocate(isp(1:nsink))
        read(ilun)isp ! Read sink index 
        idsink(1:nsink)=isp
        deallocate(isp)
!        read(ilun)ncloud_sink
        allocate(nb(1:nsink))
        read(ilun)nb ! Read newborn boolean
        new_born(1:nsink)=nb
        deallocate(nb)
        read(ilun)sinkint_level
     end if
     close(ilun)
     ! Send the token                                                                                                                                                                        
#ifndef WITHOUTMPI
     if(IOGROUPSIZE>0) then
        if(mod(myid,IOGROUPSIZE)/=0 .and.(myid.lt.ncpu))then
           dummy_io=1
           call MPI_SEND(dummy_io,1,MPI_INTEGER,myid-1+1,tag, &
                & MPI_COMM_WORLD,info2)
        end if
     endif
#endif


     call compute_ncloud_sink

     if(ir_feedback)then
        do i=1,nsink
           acc_lum(i)=ir_eff*acc_rate(i)*msink(i)/(5*6.955d10/scale_l)
        end do
     end if

  end if

  if (nrestart>0)then
     nsinkold=nsink  
     if(TRIM(initfile(levelmin)).NE.' ')then
        filename=TRIM(initfile(levelmin))//'/ic_sink_restart'
     else
        filename='ic_sink_restart'
     end if
     INQUIRE(FILE=filename, EXIST=ic_sink)
     if (myid==1)write(*,*)'Looking for file ic_sink_restart: ',filename
     if (.not. ic_sink)then
        filename='ic_sink_restart'
        INQUIRE(FILE=filename, EXIST=ic_sink)
     end if
  else
     nsink=0
     nindsink=0
     nsinkold=0
     if(TRIM(initfile(levelmin)).NE.' ')then
        filename=TRIM(initfile(levelmin))//'/ic_sink'
     else
        filename='ic_sink'
     end if
     INQUIRE(FILE=filename, EXIST=ic_sink)
     if (myid==1)write(*,*)'Looking for file ic_sink: ',filename
     if (.not. ic_sink)then
        filename='ic_sink'
        INQUIRE(FILE=filename, EXIST=ic_sink)
     end if
  end if
      
  if (ic_sink)then

     ! Wait for the token                                                                                                                                                                    
#ifndef WITHOUTMPI
     if(IOGROUPSIZE>0) then
        if (mod(myid-1,IOGROUPSIZE)/=0) then
           call MPI_RECV(dummy_io,1,MPI_INTEGER,myid-1-1,tag2,&
                & MPI_COMM_WORLD,MPI_STATUS_IGNORE,info2)
        end if
     endif
#endif
     
     open(10,file=filename,form='formatted')                                                             
     eof=.false.                                                                                         
     do                                                                                                  
        read(10,*,end=102)mm1,xx1,xx2,xx3,vv1,vv2,vv3,ll1,ll2,ll3                                        
        nsink=nsink+1
        nindsink=nindsink+1
        idsink(nsink)=nindsink
        msink(nsink)=mm1
        xsink(nsink,1)=xx1+boxlen/2.0
        xsink(nsink,2)=xx2+boxlen/2.0
        xsink(nsink,3)=xx3+boxlen/2.0
        vsink(nsink,1)=vv1
        vsink(nsink,2)=vv2
        vsink(nsink,3)=vv3
        lsink(nsink,1)=ll1
        lsink(nsink,2)=ll2
        lsink(nsink,3)=ll3
        tsink(nsink)=t
        new_born(nsink)=.true.
     end do
102  continue
     close(10)
     ! Send the token                                                                                                                                                                        
#ifndef WITHOUTMPI
     if(IOGROUPSIZE>0) then
        if(mod(myid,IOGROUPSIZE)/=0 .and.(myid.lt.ncpu))then
           dummy_io=1
           call MPI_SEND(dummy_io,1,MPI_INTEGER,myid-1+1,tag2, &
                & MPI_COMM_WORLD,info2)
        end if
     endif
#endif



  end if
  if (myid==1.and.nsink-nsinkold>0)then
     write(*,*)'sinks read from file '//filename
     write(*,'("   Id           M             x             y             z            vx            vy            vz            lx            ly            lz       ")')
     write(*,'("======================================================================================================================================================")')
     do isink=nsinkold+1,nsink                                                                           
        write(*,'(I8,2X,10(2X,E12.5))')idsink(isink),msink(isink),xsink(isink,1:ndim),&
             vsink(isink,1:ndim),lsink(isink,1:ndim)
     end do
  end if
  do isink=1,nsink
     direct_force_sink(isink)=(msink(isink) .ge. mass_sink_direct_force)
  end do  
end subroutine init_sink
!################################################################
!################################################################
!################################################################
!################################################################
subroutine compute_ncloud_sink
  use amr_commons, only:dp
  use pm_commons, only:ir_cloud,ir_cloud_massive,ncloud_sink,ncloud_sink_massive
  real(dp)::xx,yy,zz,rr
  integer::ii,jj,kk
  ! Compute number of cloud particles
  ncloud_sink=0
  ncloud_sink_massive=0
  do kk=-2*ir_cloud,2*ir_cloud
     zz=dble(kk)/2.0
     do jj=-2*ir_cloud,2*ir_cloud
        yy=dble(jj)/2.0
        do ii=-2*ir_cloud,2*ir_cloud
           xx=dble(ii)/2.0
           rr=sqrt(xx*xx+yy*yy+zz*zz)
           if(rr<=dble(ir_cloud))ncloud_sink=ncloud_sink+1
           if(rr<=dble(ir_cloud_massive))ncloud_sink_massive=ncloud_sink_massive+1
        end do
     end do
  end do
end subroutine compute_ncloud_sink

