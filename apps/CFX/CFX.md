```
Name:


cfx5solve


Purpose:


Run the ANSYS CFX Solver or the ANSYS CFX Solver Manager.


If no Solver Input File is specified on the command line the
ANSYS CFX Solver Manager will be started to allow you to select an ANSYS
CFX Solver Input File and then run the ANSYS CFX Solver. Otherwise the
ANSYS CFX Solver will be run directly unless the -interactive option is
also specified on the command line.


Synopsis:


cfx5solve -def <Solver Input File> [<options>]


cfx5solve -mdef <multi-configuration Solver Input File> [<options>]
          [-config <configname> [<config options>]]...


[]  denotes a discretionary option.
|   separates mutually exclusive options.
... following an option indicates that it may be repeated
<>  denotes that substitution of a suitable value is required.
    All other options are keywords, some of which have a short form.


Options:


Options to cfx5solve may be reordered where necessary. If an option
is specified multiple times (e.g. for the same configuration) the
option on the right will override those to its left.


-------------------------------------------------------------------------
GENERAL
-------------------------------------------------------------------------


-batch
    Run the ANSYS CFX Solver in batch mode (i.e. without starting the
    ANSYS CFX Solver Manager).


-chdir <directory>
    Set the working directory as specified.


-check-only
    When running in batch mode, this will cause cfx5solve to verify
    its options, but exit before starting any processes, and is
    mostly for use by the ANSYS CFX Solver Manager.


-display <display>
    Use the X11 server <display> instead of the X11 server
    defined by the DISPLAY environment variable.


-graphics ogl|mesa
-gr ogl|mesa
    Set the graphics mode to use for the GUI to the OpenGL (hardware)
    or MESA (software)-based version. This affects any CFX
    application started from within the ANSYS CFX Solver Manager.


-interactive
-int
-manager
    Run the interactive ANSYS CFX Solver Manager to start a new run
    and/or manage or monitor an existing run.
    This option may be combined with specific options only
    (-chdir -definition -display -eg -graphics -monitor -verbose).
    Other options will have no effect.


-monitor <file>
    When starting the Solver Manager, monitor the run represented
    by <file>, which may be an ANSYS CFX Results File or Output File.


-output-summary-option <option>
    Specify the job summary format in the solver output file.
    <option> may be set to:
    0: minimal
    1: terse format (default, no information per partition)
    2: compact format (one line per partition)
    3: verbose format (default prior to CFX-15.0)


-verbose
-v
    Specifying this option may result in additional output being sent to
    the Unix "standard output" file (normally the screen).


-------------------------------------------------------------------------
CFX RUN SPECIFICATION
-------------------------------------------------------------------------


-bak-elapsed-time <elapsed time frequency>
-baket <elapsed time frequency>
    This will cause the ANSYS CFX Solver to write a backup file every
    <elapsed time frequency> minutes, hours, seconds, etc... Elapsed
    time must be in quotes and have units in square brackets.
    eg: -baket "10 [min]" or -baket "5 [hr]"


-bg-ccl <file>
    Reads Command Language from the named file, and uses it to
    provide defaults for the current run.  If the file specifies a
    definition file for the run, the command language contained in
    that definition file will take precedence over that supplied.
    See also -ccl.


-ccl <file>
    Reads Command Language from the named file, and includes it in
    the setup of the run.  If <file> is the single character '-',
    the Command Language is read from the standard input (usually
    the terminal).  If any settings are made in the Command
    Language file which also occur on the command line to the left
    of the -ccl switch, the settings in the file will take
    precedence, as stated above.  This switch may be repeated to
    include Command Language from more than one file.
    Changes that affect the way the mesh is defined, or that affect the
    way the physics CCL relates to the topology of the mesh stored
    in the solver input file, cannot be made using the -ccl option.
    For example, locators for applying physics cannot be modified using
    the -ccl option. Such changes can, however, be made in CFX-Pre.


-config <configuration name>
    Apply subsequent options to the specified configuration.


-continue-from-file <file>
-cont-from-file <file>
    Use initial values and continue the run history from the specified
    ANSYS CFX Results File.  The mesh from the Solver Input File is used
    unless the -use-mesh-from-iv option is also specified.


-continue-from-configuration <configuration name>
-cont-from-config <configuration name>
    Use initial values and continue the run history from the most recent
    results for the specified configuration.  The mesh from the
    configuration's Solver Input File is used unless the -use-mesh-from-iv
    option is also specified.


-definition <file>
-def <file>
    Use specified file as the Solver Input File for a single configuration
    simulation.  Specifying an ANSYS CFX Results File (.res) here produces
    a restart.  See also "-mdef".


-eg <file>
-example <file>
    Run the ANSYS CFX Solver on one of the Example Definition
    files provided with the product.


-fullname <name>
    Choose names for the Output File, ANSYS CFX Results File, and the temporary
    directory based on <name> instead of the Solver Input File name.
    No numerical suffix (e.g. _001) is added to the specified name.


-initial <file>
-ini <file>
    Use initial values from the specified ANSYS CFX Results File. The mesh
    and run history from the specified file is also used unless the
    -interpolate-iv option is also specified. This option has been deprecated
    and should be replaced by "-initial-file" or "-continue-from-file"
    as appropriate.


-initial-configuration <configuration name>
-ini-conf <configuration name>
    Use initial values and continue the run history from the most recent
    results for the specified configuration.  The mesh from the Solver Input File
    is used unless the -use-mesh-from-iv option is also specified.


-initial-file <file>
-ini-file <file>
    Use initial values but discard the run history from the specified
    ANSYS CFX Results File.  The mesh from the Solver Input File is used
    unless the -use-mesh-from-iv option is also specified.


-interpolate-iv
-interp-iv
    Interpolate the solution from the initial values file, if one
    is supplied (using the -initial option), onto the mesh in the
    Solver Input File, rather than using the mesh from the initial
    values file. This option has been deprecated and should be
    replaced by "-initial-file" or "-continue-from-file" as appropriate.


-maxet <elapsed time>
-max-elapsed-time <elapsed time>
    Set the maximum elapsed time (wall clock time) that the ANSYS CFX
    Solver will run.  Elapsed time must be in quotes and have correct
    units in square brackets (eg: -maxet "10 [min]" or -maxet "5 [hr]")


-mdefinition <file>
-mdef <file>
    Use specified file as the Solver Input File for a multi-configuration
    or operating points simulation.  Specifying a multi-configuration or
    operating points ANSYS CFX Results File (.mres) here produces a restart.


-mcontinuation <file>
-mcont <file>
    Specify continuation of an operating points run from the specified
    operating points ANSYS CFX Results File (.mres).


-multiconfig
    Treat the Solver Input File as a multi-configuration input file.


-name <name>
    Choose names for the output file, ANSYS CFX Results File, and the temporary
    directory based on the problem name <name> instead of the
    Solver Input File name.


-use-mesh-from-iv
    Use the mesh from the source initial values (i.e. file or configuration)
    rather than from the Solver Input File.  This is only valid if a single
    initial values source is specified.


ADVANCED RUN SPECIFICATION


-indirect-startup
    Run the solver using the run directory, output file, and ccl specified by
    the -indirect-startup-path


-job
    Keep job file after an ANSYS CFX Solver run.  This file contains a
    brief summary of various solution values, and is most useful for
    regression purposes.


-job-part
-jobp
    Keep job file after an ANSYS CFX Partitioner run.  This file contains a
    brief summary of various solution values, and is most useful for
    regression purposes.


-lpf <license preference file>
    Specify a license preference file.


-norun
    Preprocess the Solver Input File only;
    Do not run the ANSYS CFX solver executable.
    When used with a multi-configuration Solver Input File, this option will
    produce complete Solver Input Files for the individual configurations.
    When used with the "-config" option, only the specified configuration
    is preprocessed.


-preferred-license <license name>
-P <license name>
    License used first by the ANSYS CFX Solver, given the availability of
    multiple useable licenses.
    This option has no effect and has been superseded by the -lpf option.


-respect-suffix-history
    Consider results files referenced by initial values files
    when choosing the numerical suffix (e.g. _001) added to the run name.


-save
    Do not delete any temporary files after the run. Normally the standard
    temporary files created by the ANSYS CFX Solver are deleted
    automatically after each run.


-------------------------------------------------------------------------
EXECUTION
-------------------------------------------------------------------------


-priority <level>
-pri <level>
    Set the run priority for the ANSYS CFX Solver.  <level> should
    be one of:
      CFX Levels          Nice increment     Windows Priority
     Idle (0)                   19               Low
     Low (1)                     7               BelowNormal
     Standard (2)                0               Normal
     High (3)                    0               AboveNormal
    This applies to all processes in a parallel run.  A numeric
    setting is also accepted as shown in the CFX column.  The default
    CFX setting is Standard (2), corresponding to a nice increment
    of 0 on UNIX platforms and a priority level of Normal on Windows.


-size <factor>
-S <factor>
-s <factor>
    Change the memory estimates used by the ANSYS CFX Solver by a
    factor of <factor>.  By default the memory estimates contained
    in the Solver Input File are used.  Sometimes these are
    inaccurate and this option needs to be used to increase the
    memory allocated.


-size-cat <size>
-size-nr <size>
-size-ni <size>
-size-nd <size>
-size-nc <size>
-size-nl <size>
-scat <size>
-nr <size>
-ni <size>
-nd <size>
-nc <size>
-nl <size>
    These options are for advanced users to change the memory allocation
    parameters for the ANSYS CFX Solver.  Usually, you should use
    the -size option instead.  <size> is the desired memory
    allocation in words, and may have K or M appended for kilo- or
    mega-.  If the suffix is 'x', the number is treated as a
    multiplier.


-size-mms <factor>
-smms <factor>
    Change the initial MMS catalogue size estimate used by the
    ANSYS CFX Solver by a factor of <factor>.  This option has been
    deprecated and should be replaced by -size-cat.


-size-part-mms <factor>
-smmspar <factor>
    Change the initial MMS catalogue size estimate used by the
    ANSYS CFX Partitioner by a factor of <factor>.  This option has
    been deprecated and should be replaced by -size-part-cat.


-size-cclsetup <factor>
-sizeccl <factor>
    Change the memory estimates used by the ANSYS CFX cclsetup executable
    by a factor of <factor>.


-size-cclsetup-cat <size>
-size-cclsetup-nr <size>
-size-cclsetup-ni <size>
-size-cclsetup-nd <size>
-size-cclsetup-nc <size>
-size-cclsetup-nl <size>
-scatccl <size>
-nrccl <size>
-niccl <size>
-ndccl <size>
-ncccl <size>
-nlccl <size>
    These options are the same as the -size-* options above, but give the
    sizes needed for the ANSYS CFX CCL Setup executable.


-size-interp <factor>
-sizeint <factor>
    Change the memory estimates used by the ANSYS CFX Interpolator by a
    factor of <factor>.


-size-interp-cat <size>
-size-interp-nr <size>
-size-interp-ni <size>
-size-interp-nd <size>
-size-interp-nc <size>
-size-interp-nl <size>
-scatint <size>
-nrint <size>
-niint <size>
-ndint <size>
-ncint <size>
-nlint <size>
    These options are the same as the -size-* options above, but give the
    sizes needed for the ANSYS CFX Interpolator.


-size-part <factor>
-sizepart <factor>
-size-par <factor>
-sizepar <factor>
    Change the memory estimates used by the ANSYS CFX Partitioner by a
    factor of <factor>.


-size-part-cat <size>
-size-part-nr <size>
-size-part-ni <size>
-size-part-nd <size>
-size-part-nc <size>
-size-part-nl <size>
-scatpar <size>
-nrpar <size>
-nipar <size>
-ndpar <size>
-ncpar <size>
-nlpar <size>
    These options are the same as the -size-* options above, but give the
    sizes needed for the ANSYS CFX Partitioner.


-size-maximal [<system memory fraction>]
    Use a 'maximal' memory estimate.
    The fraction of system memory may be optionally specified.
    If not specified, a default system memory fraction is used.




-size-maximal-part [<system memory fraction>]
    This option is similar to the -size-maximal option above,
    but uses a 'maximal' memory estimate for the partitioner.




-numa <option>
    Set the option for NUMA memory containment
    Valid options are:
       none (NUMA containment disabled)
       auto (NUMA containment enabled)


-affinity
    Set the option for process affinity control
       implicit (affinity not set by the solver)
       explicit (affinity explicitly set by the solver)


-thread-count-interp <nthread>
    Set the maximum number of threads used by the interpolator.




-thread-hwcap-interp <capacity fraction>
    Set the number of threads used by the interpolator
    as a fraction of those available on the current hardware.




-------------------------------------------------------------------------
PARALLEL AND PARTITIONING
-------------------------------------------------------------------------


-op-concurrency [<max jobs>]
    Run operating point jobs concurrently.
    The maximum number of concurrent jobs may be optionally specified.
    If not specified, the number of concurrent jobs is unlimited.


-parallel
-par
    Run the ANSYS CFX Solver in parallel mode. This option can be combined
    with the -part (-partition) option for a partitioning run.  If
    the -part switch is not given, the -parfile-read switch must be used
    to specify a valid partitioning information file.


-parfile-read <parfile>
    Set the name of an input partition file, used to set up
    a partitioning or parallel run.


-parfile-save
    When used with a parallel run, save the partitioning
    information to a file with the same basename as the results
    file, and the extension .par.


-parfile-write <parfile>
    Give the name of a partition file to write containing the
    information from a partitioning run.


-partition <number of partitions>
-part <number of partitions>
    Run the ANSYS CFX Solver in partitioning mode. This option should not
    be used if an existing partition file is also specified.


-part-only <number of partitions>
    Run the ANSYS CFX Solver in partitioning mode only, but do not run
    the solver.


-part-coupled
    Activate coupled partitioning mode for multidomain problems.
    This is the default.


-part-independent
    Activate independent partitioning mode for multidomain problems.
    This is not activated by default.


-part-mode <mode>
    Set the partitioning mode to use when running the partitioner.
    Valid options are:
       metis-kway  (MeTiS k-way)
       metis-rec   (MeTiS Recursive Bisection)
       simple      (Simple Assignment)
       drcb        (Directional Recursive Coordinate Bisection)
       orcb        (Optimized Recursive Coordinate Bisection)
       rcb         (Recursive Coordinate Bisection)
    Finer control over the partitioning method is available through
    the Command Language.


-part-remap
    Remap parallel processes to maximize intra-host communication
    and minimize inter-host communication.




-par-dist <host-list>
    Set the comma-separated <host-list> in the same form as is
    used in the Command Language definition.  This option does not
    require the -partition switch, as one partition is run on each
    host mentioned in the list.  To run multiple partitions on the
    same host it may be listed multiple times, or an asterisk may
    be used with the count, as in "wallaby*3,kangaroo*4" for a
    7-partition run.


    Host details are taken from the hostinfo.ccl file, if they are
    there; otherwise, if possible, the required information will be
    automatically detected.  <host> may be specified as
    [<user>@]<hostname>[:<CFX_ROOT>] if the user name or the
    ANSYS CFX installation root directory differ from the local host.


-par-host-list <host1>[,<host2>[,...]]
    When running in parallel, use the given host list.  See the
    -par-dist switch for details of the host list.


-par-local
    When running in parallel, use only the local host.  This will
    override the -par-hist or -par-host-list switches.


-serial
    Explicitly specify that a serial run is required.  Normally
    this is the default, but when restarting from a results file
    from a parallel run, the new run will also be parallel by
    default, and this switch can be used to override it.


-start-method <name>
    Use the named start method to start the ANSYS CFX Solver.  This option
    allows you to use different parallel methods, as listed in the
    ANSYS CFX Solver Manager GUI or in the etc/start-methods.ccl file,
    instead of the defaults.  For parallel start methods, you must also
    provide the -part or -par-dist option.


-------------------------------------------------------------------------
EXECUTABLE SELECTION
-------------------------------------------------------------------------


Single precision is the default for the ANSYS CFX Partitioner, Interpolator
and Solver.  The -double and -single options set the default precision for
all stages but may be overridden for each stage. E.g. To use the double
precision solver and single precision interpolator use:
-double -single-interp


These options may also be used to override setting in a CFX Command
Language from previous runs. E.g If the previous run used a double
precision solver -solver-single would force the single precision solver
to be used. Note: -single/-double will not override existing setting that
have be defined for each step.


-ccl2flow <executable>
    Run <executable> instead of the standard ANSYS CFX ccl2flow.


-ccl2flow-double
    Use the double precision ANSYS CFX ccl2flow executable.


-ccl2flow-single
    Use the single precision ANSYS CFX ccl2flow executable.


-cclsetup <executable>
    Run <executable> instead of the standard ANSYS CFX cclsetup.


-cclsetup-double
    Use the double precision ANSYS CFX cclsetup executable.


-cclsetup-single
    Use the single precision ANSYS CFX cclsetup executable.


-double
    Default to the double-precision version of the ANSYS CFX Partitioner,
    Interpolator and Solver.


-large
    Default to the large problem version of the ANSYS CFX Partitioner,
    Interpolator and Solver.


-interpolator <executable>
    Run <executable> instead of the standard ANSYS CFX Interpolator.


-interp-double
    Use the double precision ANSYS CFX Interpolator.


-interp-single
    Use the single precision ANSYS CFX Interpolator.


-interp-large
    Run the large problem interpolator for problems too large for
    the default executable.  This interpolator uses 64 bit integer
    and logical variables so it will allocate more memory than the
    default interpolator executable.


-partitioner <executable>
    Run <executable> instead of the standard ANSYS CFX Partitioner.


-part-double
    Use the double precision ANSYS CFX Partitioner.


-part-single
    Use the single precision ANSYS CFX Partitioner.


-part-large
    Run the large problem partitioner which can partition problems
    up to 2^32-1 elements.  This partitioner uses 64 bit integer
    and logical variables so it will allocate more memory than the
    default partitioning executable.


-single
    Default to the single precision version  of the ANSYS CFX Partitioner,
    Interpolator and Solver.


-solver [<os>=]<executable>[,<os>=<executable>[,...]]
-exec [<os>=]<executable>[,<os>=<executable>[,...]]
    Run <executable> instead of the standard ANSYS CFX Solver on <os>.
    If <os> is omitted the current os is assumed.
    E.g -solver "linux-amd64/mysolver.exe,linux=linux/mysolver.exe"


-solver-double
    Use the double precision ANSYS CFX Solver.


-solver-single
    Use the single precision ANSYS CFX Solver.


-solver-large
    Run the large problem solver for problems too large for
    the default executable.  This executable uses 64 bit integer
    and logical variables so it will allocate more memory than the
    default solver executable.


-------------------------------------------------------------------------
ANSYS SYSTEM COUPLING
-------------------------------------------------------------------------


-scport <port>
    For a coupled CFX Solver/System Coupling run, specify the port
    number for the ANSYS CFX Solver to establish a connection to.


-schost <host>
    For a coupled CFX Solver/System Coupling run, specify the host
    name for the ANSYS CFX Solver to establish a connection to.


-scname <name>
    For a coupled CFX Solver/System Coupling run, specify the name
    that System Coupling has assigned to identify the CFX Solver
    participant.


-------------------------------------------------------------------------
ANSYS MULTIFIELD AND PROCESS COUPLING
-------------------------------------------------------------------------


-ansys-arguments <arguments>
    For an ANSYS Multi-field run, set any additional options for
    the ANSYS Solver.


-ansys-input <file>
    For an ANSYS Multi-field run, set the ANSYS input file to use.


-ansys-input-is-complete
    For an ANSYS Multi-field run, treat the ANSYS input file as being
    complete. Do not pre-process using CCL2MF.


-ansys-installation <directory>
    For an ANSYS Multi-field run, set the ansys installation
    directory if not installed in a standard location.


-ansys-jobname <name>
    For an ANSYS Multi-field run, set the jobname to use. Default is
    ANSYS. For restarts, the jobname must be the same as the initial run.


-ansys-license <licensekey>
    For an ANSYS Multi-field run, set the license that the ANSYS
    Solver should use.


-ansys-restart <file>
    For an ANSYS Multi-field run, set a restart database for the ANSYS
    Solver to use.


-cplg-host <port@host>
    For a coupled solver run/ANSYS Multi-field run, specify the port number
    and hostname for the ANSYS CFX Solver to establish a connection to.


-mfx-run-mode <mode>
    For an ANSYS Multi-field run, specify the run mode. Valid modes are:
    "Start ANSYS and CFX"
    "Start ANSYS only"
    "Start CFX only"
    "Process Input File only"
```