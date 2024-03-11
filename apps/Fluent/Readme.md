
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
  
  
  
  
  /fsx/ansys_inc/v241/fluent/fluent24.1.0/bin/fluent -r24.1.0 -h
Usage: fluent [version] [-help] [options]
options:
  -aas            start Fluent in server mode,
  -act            load ACT Start page,
  -affinity=<x>   set processor affinity; <x>={core | sock | off>,
  -app=flremote   launches the Remote Visualization Client,
  -appscript=<scriptfile>
                  run the specified script in App,
  -case <file_path> [-data] 
                  reads the case file immediately after Fluent
                  launches; can include the data file if it
                  shares the same name as the case file,
  -cflush         flush the file cache buffer,
  -cnf=<x>        specify the hosts file,
  -command="<TUI command>" 
                  run TUI command on startup,
  -driver <name>  sets the graphics driver;
                  <name>={opengl | opengl2 | x11 | null},
  -env            show environment variables,
  -g              run without GUI or graphics,
  -gpgpu=<n>      specify number of GPGPUs per machine,
  -gpu[=<n>]      run with GPU Solver, and specify devices to
                  use as needed (where <n> is a comma-separated
                  list of devices),
  -gr             run without graphics,
  -gu             run without GUI,
  -gui_machine=<hostname>
                  specify the machine to be used for running
                  graphics-related process,
  -h<heap_size>   specify heap size for Cortex,
  -help           this listing,
  -hidden         fluent window is created but hidden,
  -host_ip=<host:ip>
                  specify the ip interface to be used by the
                  host process,
  -i <journal>    read the specified journal file,
  -license=<x>    specify the license capability;
                  <x>={enterprise | premium},
  -meshing        run Fluent in meshing mode,
  -mpi=<mpi>      specify MPI implementation;
                  <mpi>={openmpi | intel | ...},
  -mpitest        run the mpitest program instead of Fluent
                  to test the network,
  -nm             don't display mesh after reading,
  -pcheck         check the network connections before spawning
                  compute node processes,
  -platform=intel use AVX2 optimized binary;
                  This option is for processors that can
                  support AVX2 instruction set,
  -post           run a post-processing-only executable,
  -prepost        run a pre/post-processing-only executable,
  -p<ic>          specify interconnect;
                  <ic>={default | eth | ib},
  -r              list all releases,
  -r<x>           specify release <x>,
  -remote_node=<hostname>
                  specify the machine to be used for
                  executing mpirun to launch node processes,
                  if =<hostname> is skipped, it will use the
                  first cluster node in the hosts file,
  -scheduler=<scheduler>
                  specify scheduler name;
                  <scheduler>={lsf | pbs | sge | slurm},
  -scheduler_account=<account-name>
                  specify account name; for Slurm only,
  -scheduler_custom_script
                  run under job scheduler using custom script,
  -scheduler_gpn=<x>
                  specify number of GPUs per cluster node;
                  for Slurm only,
  -scheduler_headnode=<head-node>
                  specify scheduler job submission machine name,
  -scheduler_list_queues
                  list all available queues,
  -scheduler_nodeonly
                  launch cortex and host locally and submit
                  only the node processes to the cluster,
  -scheduler_opt=<opt>
                  specify scheduler additional option;
                  can be added multiple times,
  -scheduler_pe=<pe>
                  specify scheduler parallel environment;
                  for SGE only,
  -scheduler_ppn=<x>
                  specify number of node processes per
                  cluster node; for Slurm only,
  -scheduler_queue=<queue>
                  specify scheduler queue name;
                  partition for Slurm,
  -scheduler_stderr=<err-file>
                  specify scheduler stderr file,
  -scheduler_stdout=<out-file>
                  specify scheduler stdout file,
  -scheduler_tight_coupling
                  enable a job-scheduler-supported native
                  remote cluster node access mechanism,
  -scheduler_workdir=<working-directory>
                  specify working directory for scheduler job,
  -setenv="<var>=<value>" 
                  set the environment variable <var> to <value>,
  -sifile=<name>.txt
                  start Fluent and the remote
                  visualization server,
  -stream         print the memory bandwidth,
  -t<x>           specify number of processors <x>,
  -tm<x>          specify number of processors <x> for meshing,
  -ws             start web server with default options,
  -ws=<x>         start web server with session name as <x>.
                  Mutually exclusive to -ws,
  -ws-port=<x>    specify the port number for starting the
                  web server,
  -ws-portspan=<x>
                  specify the port span for starting the web server,
  -ws-js-url=<x>  specify the job service URL for registering the web server,
 (see User's guide for available options)
  
  