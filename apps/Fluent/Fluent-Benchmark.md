```
-------------------------------------------------------------
This is the standard ANSYS FLUENT benchmarks suite.
For permission to use or publish please contact ANSYS Inc..

Running FLUENT benchmarks...
                Host: ip-10-42-0-23
                Date: Sun Feb 25 09:49:22 2024
Creating benchmarks archive fluent_benchmarks.zip
On successful completion, please send this file to ANSYS Inc.
-------------------------------------------------------------

ANSYS FLUENT problem:
  open_racecar_280m|f1_racecar_140m|combustor_71m|exhaust_system_33m|lm6000_16m|landing_gear_15m|aircraft_wing_14m|combustor_12m|oil_rig_7m|sedan_4m|rotor_3m|aircraft_wing_2m|fluidized_bed_2m|ice_2m|pump_2m 

options: 
  -t<N>           Specify number of processors <N> (parallel). 
  -gpgpu<N>       Specify number of GPGPUs <N> per machine (parallel). 
  -out            Post-process transcript files. 
  -res            Post-process output files. 
  -p<comm>        Specify communicator <comm> (parallel). 
  -casdat=<dir>   Specify directory <dir> which contains case and data files. 
  -cnf=<hosts>    Specify hostfile <hosts> (parallel). 
  -path<x>        Specify root path x to Fluent.Inc 
  -iter=<n>       Specify iteration count. 
  -flexible-cycle Use flexible cycle 
  -io             Write case and data files at end of benchmark. 
  -hdfio=<mode>   Write case and data files using HDF5 io at end of benchmark. <mode>: 1=controller (default), 2=node0, 3=independent, 4=collective. 
  -pio            Write data file using parallel io at end of benchmark. 
  -norm           Do not remove case and data files at end of benchmark. 
  -zip            Compress the case and dat files during IO measurements. 
  -hdfcompr=<l>   Specify HDF5 compression level. <l>: [0-9]. 0 (default) signifies no compression. 1 is fastest compression. 9 is slowest. 
  -part=<method>  Partition method: 1=metis, 2=metis-zone, 3=force-auto. (default), 4=auto.
  -pre=<n>        Specify number of pre-iterations. 
  -prod=<product> Specify product. 
  -pthreads=<n>   Specify number of pthreads for DPM model. 
  -ri=<n>         Specify reporting interval (default=5). 
  -server         Include only server runs in results file. 
  -solver=<option>  Specify the solver seg|segregated or cpld|coupled to be used. 
  -init           Initialize solution, do not read data file. 
  -time=<n>       Specify number of timesteps. 
  -ver=<n>        Fluent version 3d or 2d or 2ddp .... 
  -nosyslog       Do not collect benchmarking system information 
  -noloadchk      Do not ckeck the system load on benchmarking system 
  -help           Print this message. 
  -quiet          No chatter. 
  -verbose        More chatter. 
  -ssh            Use ssh instead of rsh. 
```