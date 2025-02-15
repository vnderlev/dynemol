module Backup_m

   use MPI
   use type_m
   use blas95
   use MPI_definitions_m    , only : master , EnvCrew
   use parameters_m         , only : driver                     , &
      QMMM                       , &
      nuclear_matter             , &
      EnvField_                  , &
      DP_Moment                  , &
      Coulomb_                   , &
      restart , n_part
   use Solvated_M           , only : Prepare_Solvated_System
   use Babel_m              , only : Coords_from_Universe       , &
      trj
   use Structure_Builder    , only : Generate_Structure         , &
      Basis_Builder
   use tuning_m             , only : orbital                    , &
      eh_tag
   use QCModel_Huckel       , only : EigenSystem
   use Dielectric_Potential , only : Environment_SetUp
   use TD_Dipole_m          , only : wavepacket_DP
   use DP_main_m            , only : Dipole_Matrix
   use MM_dynamics_m        , only : preprocess_MM              , &
      Saving_MM_Backup
   use Data_Output          , only : Net_Charge


   public  :: Security_Copy , Restart_State , Restart_Sys

   interface Security_Copy
      module procedure Security_Copy_Eigen
      module procedure Security_Copy_Cheb
      module procedure Security_Copy_CSDM
   end interface

   interface Restart_State
      module procedure Restart_State_Eigen
      module procedure Restart_State_Cheb
      module procedure Restart_State_CSDM
   end interface

   interface Restart_Sys
      module procedure Restart_Sys_Eigen
      module procedure Restart_Sys_Cheb
   end interface

contains
!
!
!
!======================================================================================================================
   subroutine Restart_Sys_Eigen( Extended_Cell , ExCell_basis , Unit_Cell , DUAL_ket , AO_bra , AO_ket , frame , UNI_el )
!======================================================================================================================
      implicit none
      type(structure)                 , intent(out)   :: Extended_Cell
      type(STO_basis) , allocatable   , intent(out)   :: ExCell_basis(:)
      type(structure)                 , intent(inout) :: Unit_Cell
      complex*16                      , intent(in)    :: DUAL_ket (:,:)
      complex*16                      , intent(in)    :: AO_bra   (:,:)
      complex*16                      , intent(in)    :: AO_ket   (:,:)
      integer                         , intent(in)    :: frame
      type(R_eigen)                   , intent(out)   :: UNI_el

! local variables ...
      type(universe) :: Solvated_System

      select case ( nuclear_matter )

       case( "solvated_sys" )

         CALL Prepare_Solvated_System( Solvated_System , frame )

         CALL Coords_from_Universe( Unit_Cell , Solvated_System )

       case( "extended_sys" )

         CALL Coords_from_Universe( Unit_Cell , trj(frame) )

       case( "MDynamics" )

         ! MM preprocess ...
         CALL preprocess_MM( Net_Charge = Net_Charge )

       case default

         Print*, " >>> Check your nuclear_matter options <<< :" , nuclear_matter
         stop

      end select

      CALL Generate_Structure( frame )

      CALL Basis_Builder( Extended_Cell , ExCell_basis )

      if( EnvField_ .AND. (master .OR. EnvCrew) ) then

         CALL Dipole_Matrix  ( Extended_Cell , ExCell_basis )

         ! wavepacket component of the dipole vector ...
         ! decide what to do with this ############
         If( .false. ) CALL wavepacket_DP  ( Extended_Cell , ExCell_basis , AO_bra , AO_ket , Dual_ket )

         CALL Environment_SetUp  ( Extended_Cell )

      end If

! KernelCrew and ForceCrew: only calculate S_matrix and return;
! EnvCrew: follow to even_more_extended_Huckel ...
      CALL EigenSystem( Extended_Cell , ExCell_basis , UNI_el )


   end subroutine Restart_Sys_Eigen
!
!
!
!=========================================================================================================
   subroutine Security_Copy_Eigen( MO_bra , MO_ket , DUAL_bra , DUAL_ket , AO_bra , AO_ket , t , it , frame )
!=========================================================================================================
      implicit none
      complex*16              , intent(in)    :: MO_bra   (:,:)
      complex*16              , intent(in)    :: MO_ket   (:,:)
      complex*16              , intent(in)    :: DUAL_bra (:,:)
      complex*16              , intent(in)    :: DUAL_ket (:,:)
      complex*16              , intent(in)    :: AO_bra   (:,:)
      complex*16              , intent(in)    :: AO_ket   (:,:)
      real*8                  , intent(in)    :: t
      integer                 , intent(in)    :: it
      integer     , optional  , intent(in)    :: frame

! local variables ...
      integer         :: i , j , basis_size
      logical , save  :: first_time = .true.
      logical         :: exist
      real            :: start_time, end_time

      call CPU_TIME(start_time)
      write( * , 230 , advance='no' )  it , frame , t

! check whether restart conditions are properly set ...
      If( first_time ) then

         If( restart ) then
            inquire( file=dynemolworkdir//"Security_copy.dat", EXIST=exist )
            If( exist ) stop " <Security_copy.dat> exists; check restart parameter or move Security_copy.dat to Restart_copy.dat"
         else
            inquire( file=dynemolworkdir//"Restart_copy.dat", EXIST=exist )
            If( exist ) stop " <Restart_copy.dat> exists; check restart parameter or delete Restart_copy.dat"
         end If

         ! get rid of Restart_copy.dat for new Security_copy.dat ...
         inquire( file=dynemolworkdir//"Restart_copy.dat", EXIST=exist )
         If( exist ) CALL system( "rm Restart_copy.dat" )

         first_time = .false.

      end If

      if( nuclear_matter == "MDynamics" ) CALL Saving_MM_Backup( frame , instance = "from_QM" )

      open(unit=33, file="ancillary.trunk/Security_copy.dat", status="unknown", form="unformatted", action="write")

      if( present(frame) ) write(33) frame
      write(33) it
      write(33) t
      write(33) size(MO_bra(:,1))
      write(33) size(MO_bra(1,:))
      write(33) size(eh_tag)

      basis_size = size(MO_bra(:,1))

      write(33) ( orbital(i) , eh_tag(i) , i=1,n_part )

      do j = 1 , n_part

         write(33) ( MO_bra(i,j)   , MO_ket   (i,j) , i=1,basis_size )

         write(33) ( DUAL_bra(i,j) , DUAL_ket (i,j) , i=1,basis_size )

         write(33) ( AO_bra(i,j)   , AO_ket   (i,j) , i=1,basis_size )

      end do

      write(33) ( Net_Charge , i=1,size(Net_Charge) )

      close( 33 )

      Print*, 'DONE <<<'
      call CPU_TIME(end_time)
      print *, 'Total Security_Copy execution time: ', end_time - start_time, ' seconds'

      include 'formats.h'

   end subroutine Security_Copy_Eigen
!
!
!
!=========================================================================================================
   subroutine Restart_State_Eigen( MO_bra , MO_ket , DUAL_bra , DUAL_ket , AO_bra , AO_ket , t , it , frame )
!=========================================================================================================
      implicit none
      complex*16  , allocatable   , intent(out) :: MO_bra     (:,:)
      complex*16  , allocatable   , intent(out) :: MO_ket     (:,:)
      complex*16  , allocatable   , intent(out) :: DUAL_bra   (:,:)
      complex*16  , allocatable   , intent(out) :: DUAL_ket   (:,:)
      complex*16  , allocatable   , intent(out) :: AO_bra     (:,:)
      complex*16  , allocatable   , intent(out) :: AO_ket     (:,:)
      real*8                      , intent(out) :: t
      integer                     , intent(out) :: it
      integer     , optional      , intent(out) :: frame

! local variables ...
      integer :: i , j , size_r , size_c , file_err , size_eh_tag

      open(unit=33, file="Restart_copy.dat", form="unformatted", status="old", action="read" , iostat=file_err , err=11 )

      if( present(frame) ) read(33) frame
      read(33) it
      read(33) t
      read(33) size_r
      read(33) size_c
      read(33) size_eh_tag

      allocate( MO_bra   ( size_r , size_c ) )
      allocate( MO_ket   ( size_r , size_c ) )
      allocate( DUAL_bra ( size_r , size_c ) )
      allocate( DUAL_ket ( size_r , size_c ) )
      allocate( AO_bra   ( size_r , size_c ) )
      allocate( AO_ket   ( size_r , size_c ) )

      if( .NOT. allocated( orbital) ) allocate( orbital(size_eh_tag) )
      if( .NOT. allocated( eh_tag ) ) allocate( eh_tag(size_eh_tag) )

      read(33) ( orbital(i) , eh_tag(i) , i=1,size_eh_tag )

      do j = 1 , size_c

         read(33) ( MO_bra(i,j)   , MO_ket   (i,j) , i=1,size_r )

         read(33) ( DUAL_bra(i,j) , DUAL_ket (i,j) , i=1,size_r )

         read(33) ( AO_bra(i,j)   , AO_ket   (i,j) , i=1,size_r )

      end do

      read(33) ( Net_Charge , i=1,size(Net_Charge) )

      close( 33 )

11    if( file_err > 0 ) then
         CALL warning("<Restart_copy.dat> file not found; terminating execution")
         stop
      endif

   end subroutine Restart_State_Eigen
!
!
!
!================= Chebyshev Routines =====================
!
!
!
!============================================================================================================
   subroutine Restart_Sys_Cheb( Extended_Cell , ExCell_basis , Unit_Cell , DUAL_ket , AO_bra , AO_ket , frame )
!============================================================================================================
      implicit none
      type(structure)                 , intent(out)   :: Extended_Cell
      type(STO_basis) , allocatable   , intent(out)   :: ExCell_basis(:)
      type(structure)                 , intent(inout) :: Unit_Cell
      complex*16                      , intent(in)    :: DUAL_ket (:,:)
      complex*16                      , intent(in)    :: AO_bra   (:,:)
      complex*16                      , intent(in)    :: AO_ket   (:,:)
      integer                         , intent(in)    :: frame

! local variables ...
      type(universe) :: Solvated_System

      select case ( nuclear_matter )

       case( "solvated_sys" )

         CALL Prepare_Solvated_System( Solvated_System , frame )

         CALL Coords_from_Universe( Unit_Cell , Solvated_System )

       case( "extended_sys" )

         CALL Coords_from_Universe( Unit_Cell , trj(frame) )

       case( "MDynamics" )

         ! MM preprocess ...
         CALL preprocess_MM( Net_Charge = Net_Charge )

       case default

         Print*, " >>> Check your nuclear_matter options <<< :" , nuclear_matter
         stop

      end select

      CALL Generate_Structure ( frame )

      CALL Basis_Builder ( Extended_Cell , ExCell_basis )

      if( EnvField_ ) then

         CALL Dipole_Matrix  ( Extended_Cell , ExCell_basis )

         ! wavepacket component of the dipole vector ...
         ! decide what to do with this ############
         If( .false. ) CALL wavepacket_DP  ( Extended_Cell , ExCell_basis , AO_bra , AO_ket , Dual_ket )

         CALL Environment_SetUp  ( Extended_Cell )

      end If

   end subroutine Restart_Sys_Cheb
!
!
!
!=======================================================================================
   subroutine Security_Copy_Cheb( Dual_bra , Dual_ket , AO_bra , AO_ket , t , it , frame )
!=======================================================================================
      implicit none
      complex*16              , intent(in) :: DUAL_bra   (:,:)
      complex*16              , intent(in) :: DUAL_ket   (:,:)
      complex*16              , intent(in) :: AO_bra     (:,:)
      complex*16              , intent(in) :: AO_ket     (:,:)
      real*8                  , intent(in) :: t
      integer                 , intent(in) :: it
      integer     , optional  , intent(in) :: frame

! local variables ...
      integer         :: i , j , basis_size
      logical , save  :: first_time = .true.
      logical         :: exist
      real            :: start_time, end_time

      call CPU_TIME(start_time)
      write( * , 230 , advance='no' )  it , frame , t

! check whether restart conditions are properly set ...
      If( first_time ) then

         If( restart ) then
            inquire( file=dynemolworkdir//"Security_copy.dat", EXIST=exist )
            If( exist ) stop " <Security_copy.dat> exists; check restart parameter or move Security_copy.dat to Restart_copy.dat"
         else
            inquire( file=dynemolworkdir//"Restart_copy.dat", EXIST=exist )
            If( exist ) stop " <Restart_copy.dat> exists; check restart parameter or delete Restart_copy.dat"
         end If

         ! get rid of Restart_copy.dat for new Security_copy.dat ...
         inquire( file=dynemolworkdir//"Restart_copy.dat", EXIST=exist )
         If( exist ) CALL system( "rm Restart_copy.dat" )

         first_time = .false.

      end If

      if( nuclear_matter == "MDynamics" ) CALL Saving_MM_Backup( frame , instance = "from_QM" )

      open(unit=33, file="ancillary.trunk/Security_copy.dat", status="unknown", form="unformatted", action="write")

      if( present(frame) ) write(33) frame
      write(33) it
      write(33) t
      write(33) size(AO_bra(:,1))
      write(33) size(AO_bra(1,:))
      write(33) size(eh_tag)

      basis_size = size(AO_bra(:,1))

      write(33) ( eh_tag(i) , i=1,n_part )

      do j = 1 , n_part
         write(33) ( DUAL_bra(i,j) , DUAL_ket (i,j) , i=1,basis_size )
         write(33) ( AO_bra(i,j)   , AO_ket   (i,j) , i=1,basis_size )
      end do

      write(33) ( Net_Charge , i=1,size(Net_Charge) )

      close( 33 )

      Print*, 'DONE <<<'
      call CPU_TIME(end_time)
      print *, 'Total Security_Copy execution time: ', end_time - start_time, ' seconds'

      include 'formats.h'

   end subroutine Security_Copy_Cheb
!
!
!
!======================================================================================
   subroutine Restart_State_Cheb( DUAL_bra , DUAL_ket , AO_bra , AO_ket , t , it , frame )
!======================================================================================
      implicit none
      complex*16  , allocatable   , intent(out) :: DUAL_bra   (:,:)
      complex*16  , allocatable   , intent(out) :: DUAL_ket   (:,:)
      complex*16  , allocatable   , intent(out) :: AO_bra     (:,:)
      complex*16  , allocatable   , intent(out) :: AO_ket     (:,:)
      real*8                      , intent(out) :: t
      integer                     , intent(out) :: it
      integer     , optional      , intent(out) :: frame

! local variables ...
      integer :: i , j , size_r , size_c , file_err , size_eh_tag

      open(unit=33, file="Restart_copy.dat", form="unformatted", status="old", action="read" , iostat=file_err , err=11 )

      if( present(frame) ) read(33) frame
      read(33) it
      read(33) t
      read(33) size_r
      read(33) size_c
      read(33) size_eh_tag

      allocate( DUAL_bra ( size_r , size_c ) )
      allocate( DUAL_ket ( size_r , size_c ) )
      allocate( AO_bra   ( size_r , size_c ) )
      allocate( AO_ket   ( size_r , size_c ) )

      if( .NOT. allocated( eh_tag ) ) allocate( eh_tag(size_eh_tag) )

      read(33) ( eh_tag(i) , i=1,size_eh_tag )

      do j = 1 , size_c
         read(33) ( DUAL_bra(i,j) , DUAL_ket (i,j) , i=1,size_r )
         read(33) ( AO_bra(i,j)   , AO_ket   (i,j) , i=1,size_r )
      end do

      read(33) ( Net_Charge , i=1,size(Net_Charge) )

      close( 33 )

11    if( file_err > 0 ) then
         CALL warning("<Restart_copy.dat> file not found; terminating execution")
         stop
      endif

   end subroutine Restart_State_Cheb
!
!
!
!
!================= CSDM Routines =====================
!
!
!
!
!=============================================================================================================================================
   subroutine Security_Copy_CSDM  &
      ( MO_bra , MO_ket , MO_TDSE_bra , MO_TDSE_ket , DUAL_bra , DUAL_ket , DUAL_TDSE_bra , DUAL_TDSE_ket , AO_bra , AO_ket , PST , t , it , frame )
!=============================================================================================================================================
      implicit none
      complex*16 , intent(in) :: MO_bra        (:,:)
      complex*16 , intent(in) :: MO_ket        (:,:)
      complex*16 , intent(in) :: MO_TDSE_bra   (:,:)
      complex*16 , intent(in) :: MO_TDSE_ket   (:,:)
      complex*16 , intent(in) :: DUAL_bra      (:,:)
      complex*16 , intent(in) :: DUAL_ket      (:,:)
      complex*16 , intent(in) :: DUAL_TDSE_bra (:,:)
      complex*16 , intent(in) :: DUAL_TDSE_ket (:,:)
      complex*16 , intent(in) :: AO_bra        (:,:)
      complex*16 , intent(in) :: AO_ket        (:,:)
      integer    , intent(in) :: PST(2)
      real*8     , intent(in) :: t
      integer    , intent(in) :: it
      integer    , intent(in) :: frame

! local variables ...
      integer         :: i , j , basis_size
      logical , save  :: first_time = .true.
      logical         :: exist
      real            :: start_time, end_time

      call CPU_TIME(start_time)
      write( * , 230 , advance='no' )  it , frame , t , end_time - start_time

! check whether restart conditions are properly set ...
      If( first_time ) then

         If( restart ) then
            inquire( file=dynemolworkdir//"Security_copy.dat", EXIST=exist )
            If( exist ) stop " <Security_copy.dat> exists; check restart parameter or move Security_copy.dat to Restart_copy.dat"
         else
            inquire( file=dynemolworkdir//"Restart_copy.dat", EXIST=exist )
            If( exist ) stop " <Restart_copy.dat> exists; check restart parameter or delete Restart_copy.dat"
         end If

         ! get rid of Restart_copy.dat for new Security_copy.dat ...
         inquire( file=dynemolworkdir//"Restart_copy.dat", EXIST=exist )
         If( exist ) CALL system( "rm Restart_copy.dat" )

         first_time = .false.

      end If

      CALL Saving_MM_Backup( frame , instance = "from_QM" )

      open(unit=33, file="ancillary.trunk/Security_copy.dat", status="unknown", form="unformatted", action="write")

      write(33) frame
      write(33) it
      write(33) t
      write(33) PST
      write(33) size(MO_bra(:,1))
      write(33) size(MO_bra(1,:))
      write(33) size(eh_tag)

      basis_size = size(MO_bra(:,1))

      write(33) ( orbital(i) , eh_tag(i) , i=1,n_part )

      do j = 1 , n_part

         write(33) ( MO_bra(i,j)        , MO_ket   (i,j)      , i=1,basis_size )

         write(33) ( MO_TDSE_bra(i,j)   , MO_TDSE_ket   (i,j) , i=1,basis_size )

         write(33) ( DUAL_bra(i,j)      , DUAL_ket (i,j)      , i=1,basis_size )

         write(33) ( DUAL_TDSE_bra(i,j) , DUAL_TDSE_ket (i,j) , i=1,basis_size )

         write(33) ( AO_bra(i,j)        , AO_ket   (i,j)      , i=1,basis_size )

      end do

      write(33) ( Net_Charge , i=1,size(Net_Charge) )

      close( 33 )

      Print*, 'DONE <<<'
      call CPU_TIME(end_time)
      print *, 'Total Security_Copy execution time: ', end_time - start_time, ' seconds'

      include 'formats.h'

   end subroutine Security_Copy_CSDM
!
!
!
!=============================================================================================================================================
   subroutine Restart_State_CSDM  &
      ( MO_bra , MO_ket , MO_TDSE_bra , MO_TDSE_ket , DUAL_bra , DUAL_ket , DUAL_TDSE_bra , DUAL_TDSE_ket , AO_bra , AO_ket , PST , t , it , frame )
!=============================================================================================================================================
      implicit none
      complex*16  , allocatable   , intent(out) :: MO_bra        (:,:)
      complex*16  , allocatable   , intent(out) :: MO_ket        (:,:)
      complex*16  , allocatable   , intent(out) :: MO_TDSE_bra   (:,:)
      complex*16  , allocatable   , intent(out) :: MO_TDSE_ket   (:,:)
      complex*16  , allocatable   , intent(out) :: DUAL_bra      (:,:)
      complex*16  , allocatable   , intent(out) :: DUAL_ket      (:,:)
      complex*16  , allocatable   , intent(out) :: DUAL_TDSE_bra (:,:)
      complex*16  , allocatable   , intent(out) :: DUAL_TDSE_ket (:,:)
      complex*16  , allocatable   , intent(out) :: AO_bra        (:,:)
      complex*16  , allocatable   , intent(out) :: AO_ket        (:,:)
      integer                     , intent(out) :: PST(2)
      real*8                      , intent(out) :: t
      integer                     , intent(out) :: it
      integer                     , intent(out) :: frame

! local variables ...
      integer :: i , j , size_r , size_c , file_err , size_eh_tag

      open(unit=33, file="Restart_copy.dat", form="unformatted", status="old", action="read" , iostat=file_err , err=11 )

      read(33) frame
      read(33) it
      read(33) t
      read(33) PST
      read(33) size_r
      read(33) size_c
      read(33) size_eh_tag

      allocate( MO_bra        ( size_r , size_c ) )
      allocate( MO_ket        ( size_r , size_c ) )
      allocate( MO_TDSE_bra   ( size_r , size_c ) )
      allocate( MO_TDSE_ket   ( size_r , size_c ) )
      allocate( DUAL_bra      ( size_r , size_c ) )
      allocate( DUAL_ket      ( size_r , size_c ) )
      allocate( DUAL_TDSE_bra ( size_r , size_c ) )
      allocate( DUAL_TDSE_ket ( size_r , size_c ) )
      allocate( AO_bra        ( size_r , size_c ) )
      allocate( AO_ket        ( size_r , size_c ) )

      if( .NOT. allocated( orbital) ) allocate( orbital(size_eh_tag) )
      if( .NOT. allocated( eh_tag ) ) allocate( eh_tag(size_eh_tag) )

      read(33) ( orbital(i) , eh_tag(i) , i=1,size_eh_tag )

      do j = 1 , size_c

         read(33) ( MO_bra(i,j)        , MO_ket(i,j)        , i=1,size_r )

         read(33) ( MO_TDSE_bra(i,j)   , MO_TDSE_ket(i,j)   , i=1,size_r )

         read(33) ( DUAL_bra(i,j)      , DUAL_ket(i,j)      , i=1,size_r )

         read(33) ( DUAL_TDSE_bra(i,j) , DUAL_TDSE_ket(i,j) , i=1,size_r )

         read(33) ( AO_bra(i,j)        , AO_ket(i,j)        , i=1,size_r )

      end do

      read(33) ( Net_Charge , i=1,size(Net_Charge) )

      close( 33 )

11    if( file_err > 0 ) then
         CALL warning("<Restart_copy.dat> file not found; terminating execution")
         stop
      endif

   end subroutine Restart_State_CSDM
!
!
!
!
end module Backup_m
