/**
 * RunAndTimeSimulation.java - Automated CFD benchmarking macro for STAR-CCM+.
 *
 * Runs configurable warmup + timed iterations, measures solve time and memory,
 * exports all simulation reports, writes results to CSV and JSON.
 *
 * DEPENDENCIES:
 *   - ExportCaseInfo.java (optional) — runs as a post-run macro to export
 *     scene images and case metadata. If not present, the macro prints a
 *     warning but continues. To disable, set postRunMacro={""} below.
 *   - benchmark_config.properties (optional) — if present in the working
 *     directory, overrides default settings (clearSolution, presteps,
 *     runsteps, etc.). Useful for per-simulation configuration without
 *     editing this file.
 *
 * USAGE:
 *   starccm+ -batch RunAndTimeSimulation.java model.sim
 *
 * OUTPUT:
 *   - BenchmarkReport.csv — timing results (one row per run)
 *   - benchmark.json — same data in JSON format with metadata
 *   - MasterBenchmarkReport.csv — appended to /fsx/benchmarks/ (if writable)
 *
 * STEADY vs UNSTEADY:
 *   The macro auto-detects unsteady simulations (ImplicitUnsteadySolver).
 *   For steady sims, presteps/runsteps are iterations.
 *   For unsteady sims, presteps/runsteps are time steps (each containing
 *   multiple inner iterations). Maximum Physical Time and Maximum Inner
 *   Iterations criteria are kept enabled as safety nets for unsteady runs.
 *
 * Last updated: 2026-04-09
 *
 * @since STAR-CCM+ v18.02 (2302), Apr 2023
 * @author Max Starr, AWS
 */

package macro;

import star.automation.SimDriverWorkflow;
import star.automation.SimDriverWorkflowManager;
import star.common.*;
import star.meshing.MeshPipelineController;
import star.base.neo.*;
import star.base.report.*;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.IOException;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Date;
import java.util.regex.Pattern;
import java.util.*; //Need to fix this for the java.util.Treeset function

/**
* This allows users to time STAR-CCM+, but provides a range of options to
* increase flexibility and control.
* Timing is done within the macro; this removes the time taken to carry out
* actions such as loading STAR-CCM+ and loading/partitioning sim files. These
* actions can take some time to complete, and are dependent on a range of 
* uncontrollable factors (e.g. beyond just disc read speeds, network traffic on
* a shared file system could cause slow file loading).
*
* There are a range of controls, set by the user in the first part of this macro
* with a range of variables that are set - boolean, integers and string values
* to be set. The user can choose whether the simulation should be remeshed,
* saved at intermediate or final points, how many iterations should be run, and
* more, and all of these actions are timed in separate steps. Those timings
* are exported to two csv files by default; one in a location local to the 
* sim file, and another that can be considered a master in a hard coded location
* of the users choice. I use this to write out results for _all_ my simulations
* to a constant file, both for backup and historical measurement purposes (i.e.
* a single csv file that forever lives near the root of my shared file system).
*
* Note that this code is effectively unsupported and used at user discretion.
* It is written in a fairly readable form so is easy to check that there are
* no nasties.
*/

public class RunAndTimeSimulation extends StarMacro {

/******
* IGNORE
******/
// Variables that are used in the macro below but don't need to be changed by the user.
// Keep scrolling down.
    Simulation sim;
    String simName, simDir, splittingSep="\\";
    public ArrayList<timing> totalTimes = new ArrayList<>();
    public ArrayList<jsonoutput> jsonData = new ArrayList<>();
    long thisStartTime = (long) 0.0;
    long totalStartTime = (long) 0.0;
	String sep = java.io.File.separator;
/******
* END OF IGNORANCE
******/


/**
* Variables to change macro behaviour.
* You'd like to change the way the macro is controlling your sim file? This
* is the section where you change variables to change what is done.
*
*/

/******
* OVERALL CONTROLS
******/
	
    // Clear the historical fields in the simulation?
    // Note; this is not the same as clearing a previous solution, this just
    // empties any plots/monitors of data.
    boolean clearHistory = true;

    // Clear any previous solution that has been run in the simulation?
    boolean clearSolution = true;

    // Delete any existing meshes? This is a clear-all option; takes the
    // simulation back to the imported geometry level. To-do: allow the option
    // to just remove volume meshes.
    boolean clearMesh = false;

    // Remesh in case any mesh settings have been changed. Can be true even if
    // the mesh isn't clear. But if this is done, the mesh is updated. If the
    // mesh has been cleared above, this MUST be true or the simulation won't
    // solve.
    boolean updateMesh = false;

    // Save (but doesn't measure the save times of) simulations at various
    // points in the code and at the end.
    // NOTE THAT THIS WILL OVERWRITE THE SOURCE SIM FILE
    // This is good if you have a simulation that will run for a long time.
    // Generally if you're just doing benchmarking, leaving this set as false is fine
    // as it can save significant time and space.
    boolean saveSimulations = false;

    // Save the sim file at different steps and measure the save time.
    // If you don't want to measure your filesystem I/O and are just benchmarking,
    // leave this to false. Otherwise it wastes time and disc space.
    boolean saveFinalSimulations = false;

    // Perform the iteration/solve steps for timing.
    // Generally if you're benchmarking the code, this is what you want to have set to
    // true, if nothing else.
    boolean solve = true;
    
    // Measure the memory usage of the simulation by doing another step at the end with a
    // memory measurement report. We don't run this report throughout the simulation run
    // as it can slow down the simulation process.
    boolean measureMemory = true;
    
    
/******
* SOLVING CONTROLS
******/
    
    // A relatively recent addition to STAR-CCM+ is the ability to control simulations
    // with loops and changes within the simulation, rather than using Java macros.
    // (NNnnnnoooooooo!!!!)
    // If you want to use that workflow change this setting to True. 
    // NOTE that setting this to true overrides the following options for:
    // - Iteration choices
    // - Macros to run
    // As both of these are controlled by the simulation controller workflow
    boolean useSimDriverWorkFlow = false;
    // NOTE2: this is currently a WIP, so leave on false.
    
    
    
    // Do you want to run a custom number of iterations (as opposed to whatever the 
    // stopping criteria are set as within the simulation)? Note that this assumes the
    // simulation doesn't use simulation controllers and instead only uses standard set up.
    boolean changeRunIterations = true;
    // Follows from above choice. Generally, when running a simulation, the first 10
    // iterations (or so) require memory allocation and declaration and so these processes
    // can skew benchmark timing. This can still happen during the first 100 iterations,
    // so best practice is to discard the first 100 iterations for timing purposes. These
    // are called the pre-solve iterations.
    int presteps = 100;
    // How many iterations to run for the timing.
    int runsteps = 500;
    // Note also that I've (lazily) used steps and iterations interchangably here. If your
    // simulation is an unsteady one, then time steps are used. If it's steady, iterations
    // are used.
    
    // WIP
    // Set maximum wall clock time for the simulation to run by (and still end cleanly - 
    // which wouldn't happen if you set a maximum wall clock time in the SLURM script).
    boolean stopAfterSpecifiedRuntime=false;
    int secondsToStopSimulationAfter=7200;
    
    
    // Run custom macros at various steps if desired. Each macro's execution is timed in
    // its entirety; if you want timing on actions within the macro that macro needs to
    // contain its own timing.
    // These are array variables, so add multiple macros as {"a.java","b.java",..."z.java"}
    // Note that these files are paths relative to where the simulation was launched from.
    // For simplicity, keep a copy of all macros in the same directory as the simulation
    // file and launch from that directory too.
    String[] preMeshMacro={""};
    String[] postMeshMacro={""};
    String[] postRunMacro={"ExportCaseInfo.java"};
	
	// If we want to control the simulation RUN with a specified macro to solve
	// the simulation rather than the built in iterator code; this is in case we have a
	// supplied macro that makes its own changes. We only allow 1 macro here, as we're
	// timing the whole length of that process.
	boolean useRunMacro = false; 
	String runMacro="";
	
    
/******
* EXPORT CONTROLS
******/
    

    
    // What file do you want benchmark data to go to? Relative to the sim file directory.
    // (Note: always placed one directory up from the sim file run directory by default)
    String exportFile = "BenchmarkReport.csv";
    
    
    // Work in progress (to be developed)
    boolean measureMaximumRAMusage = false;
    
    // If you want to export all reports, set this to true and they will be appended to
    // the line of the benchmark results, at the end.
    boolean exportAllReports=true;
    // Export particular reports and parameters if required so comparisons of physical
    // values can be made. WIP
    String[] paramsToExport = {};
    String[] reportsToExport = {};
    
	// Maintain a master benchmark results list somewhere to write to.
	// It can be useful to have _all_ simulations write their results to a single
	// file regardless of the benchmark being run; this allows for a single source of
	// truth to be maintained. This can be placed in the root shared directory for
	// example.
    boolean writeResultsToMasterFile = true;
    String masterFileLoc = "/fsx/benchmarks/MasterBenchmarkReport.csv";
    boolean writeToJSON=true;
    
    
    boolean writeSummaryFile=false; // WIP    
    
    boolean exportAllScenes=false; //WIP

    
/******
* THE REST IS CODE
******/
  public void execute() {
    // Get the current simulation object
    sim = getActiveSimulation();
	totalStartTime = new Date().getTime();

	// Read optional benchmark_config.properties from the working directory.
	// This allows the orchestrator to override macro settings per-job without
	// editing the Java file. Supported keys: clearSolution, clearHistory,
	// clearMesh, presteps, runsteps, measureMemory, exportAllReports.
	try {
	    java.io.File configFile = new java.io.File("benchmark_config.properties");
	    if (configFile.exists()) {
	        java.util.Properties props = new java.util.Properties();
	        props.load(new java.io.FileReader(configFile));
	        sim.println("[CONFIG] Reading benchmark_config.properties");
	        if (props.containsKey("clearSolution")) {
	            clearSolution = Boolean.parseBoolean(props.getProperty("clearSolution"));
	            sim.println("[CONFIG] clearSolution = " + clearSolution);
	        }
	        if (props.containsKey("clearHistory")) {
	            clearHistory = Boolean.parseBoolean(props.getProperty("clearHistory"));
	            sim.println("[CONFIG] clearHistory = " + clearHistory);
	        }
	        if (props.containsKey("clearMesh")) {
	            clearMesh = Boolean.parseBoolean(props.getProperty("clearMesh"));
	            sim.println("[CONFIG] clearMesh = " + clearMesh);
	        }
	        if (props.containsKey("presteps")) {
	            presteps = Integer.parseInt(props.getProperty("presteps"));
	            sim.println("[CONFIG] presteps = " + presteps);
	        }
	        if (props.containsKey("runsteps")) {
	            runsteps = Integer.parseInt(props.getProperty("runsteps"));
	            sim.println("[CONFIG] runsteps = " + runsteps);
	        }
	    }
	} catch (Exception ex) {
	    sim.println("[CONFIG] Warning: could not read benchmark_config.properties: " + ex);
	}
	//sep = System.getProperty("file.separator");
	splittingSep = Pattern.quote(System.getProperty("file.separator"));
	simName = sim.getPresentationName().replace(".sim","");
	simDir = sim.getSessionDir() + sep;
	// Write BenchmarkReport.csv to the current working directory (the job directory),
	// not relative to the sim file location.
	exportFile = System.getProperty("user.dir") + sep + exportFile;
	
	// turn off all the auto save features because we want to control when the save
	// points happen within this batch script.
    AutoSave autoSave = sim.getSimulationIterator().getAutoSave();
	// Turn off auto save after volume meshing
    autoSave.setAutoSaveMesh(false);
    // Turn off auto save after batch runs
    autoSave.setAutoSaveBatch(false);
    // Turn off autosave during simulation (i.e. at specific iterations;
    // in case the sim file has this turned on).
    autoSave.getStarUpdate().setEnabled(false);
	
	
	if (clearSolution) {
        sim.getSolution().clearSolution(Solution.Clear.History, Solution.Clear.Fields);
    }
    if (clearMesh) {
        sim.get(MeshPipelineController.class).clearGeneratedMeshes();
    }
    if (clearHistory) {
        sim.getSolution().clearSolution(Solution.Clear.History);
    }
    
    if (saveSimulations) {
        sim.saveState(resolvePath(simDir+simName));
    }
    
    
    if (saveFinalSimulations && clearSolution && clearMesh && clearHistory) {
        thisStartTime = new Date().getTime();
        sim.saveState(resolvePath(sim.getSessionDir() + java.io.File.separator + "clear.sim"));
        logTime(thisStartTime, "Save clear.sim");
    }
    if (saveFinalSimulations && clearSolution && clearHistory) {
        thisStartTime = new Date().getTime();
        sim.saveState(resolvePath(sim.getSessionDir() + java.io.File.separator + "mesh.sim"));
        logTime(thisStartTime, "Save mesh.sim");
    }
    
    
    
    if (useSimDriverWorkFlow) {
        useSimDriverWorkFlowRunner();
    } else {
        useStandardWorkFlow();
    }
    
    

    logTime(totalStartTime, "Total Run Time (s)");
  
    compileTimings();
  }
  
  public void useStandardWorkFlow() {
  

	if (clearMesh || updateMesh) {
	    thisStartTime = new Date().getTime();
	    sim.get(MeshPipelineController.class).generateSurfaceMesh();
	    logTime(thisStartTime, "Surface Mesh Generation");

	    thisStartTime = new Date().getTime();
	    sim.get(MeshPipelineController.class).generateVolumeMesh();
	    logTime(thisStartTime, "Volume Mesh Generation");
	}
	
	if (postMeshMacro.length>0) {
	    for (String mac:postMeshMacro) {
	    	try {
		    	sim.println("Running post mesh macro: "+mac);
		    	new StarScript(sim, new File(mac)).play();
		    	sim.println("Completed post mesh macro: "+mac);
		    } catch (Exception e) {
		    	sim.println("Failed post mesh macro: "+mac+" because: "+e);
		    }
	    }
	}


    /// Commented out for V
	if (!useRunMacro) {
		// Get the steps stopping criterion.
		 StepStoppingCriterion stepStopCrit = getOrMakeMaximumStepsCriterion();
		 stepStopCrit.setIsUsed(true);

		 // Detect whether this is an unsteady simulation.
		 // For unsteady sims, "steps" are time steps (each containing multiple
		 // inner iterations). For steady sims, "steps" are iterations.
		 // StepStoppingCriterion counts time steps for unsteady, iterations for steady.
		 boolean isUnsteady = false;
		 try {
		     sim.getSolverManager().getSolver(ImplicitUnsteadySolver.class);
		     isUnsteady = true;
		 } catch (Exception e) {
		     // Not unsteady — steady sim
		 }
		 sim.println("[Benchmark] Simulation type: " + (isUnsteady ? "UNSTEADY" : "STEADY"));

		 // Disable stopping criteria that might interfere with benchmarking.
		 // For steady sims: disable everything except StepStoppingCriterion.
		 // For unsteady sims: keep Maximum Physical Time and Maximum Inner
		 // Iterations as safety nets. Disabling Inner Iterations causes each
		 // time step to run unlimited inner iterations instead of the configured count.
		 if (changeRunIterations) {
		     for (Object sc : sim.getSolverStoppingCriterionManager().getObjects()) {
		         if (sc instanceof StepStoppingCriterion) continue;
		         String scName = sc.toString();
		         // Keep these criteria for unsteady sims
		         if (isUnsteady && (scName.contains("Physical Time") || scName.contains("Inner Iterations"))) {
		             sim.println("[Benchmark] Keeping stopping criterion: " + scName);
		             continue;
		         }
		         try {
		             ((star.common.SolverStoppingCriterion) sc).setIsUsed(false);
		             sim.println("[Benchmark] Disabled stopping criterion: " + sc);
		         } catch (Exception e) {
		             sim.println("[Benchmark] Could not disable criterion: " + sc + " — " + e);
		         }
		     }
		 }

		 // Get the current step count. For unsteady sims, use getCurrentTimeLevel()
		 // which returns the time step number. For steady sims, use getCurrentIteration().
		 // StepStoppingCriterion operates on the same counter as these methods.
		 int currentStep;
		 if (isUnsteady) {
		     currentStep = sim.getSimulationIterator().getCurrentTimeLevel();
		     sim.println("[Benchmark] Current time step (getCurrentTimeLevel): " + currentStep);
		     sim.println("[Benchmark] Current iteration (getCurrentIteration): " + sim.getSimulationIterator().getCurrentIteration());
		 } else {
		     currentStep = sim.getSimulationIterator().getCurrentIteration();
		 }
		 sim.println("[Benchmark] Current step: " + currentStep);

		// Pre-solve steps to remove the slower initial solve steps. Optional.
		if (changeRunIterations) {
			stepStopCrit.setMaximumNumberSteps(currentStep + presteps);
			sim.println("[Benchmark] Pre-solve: running " + presteps + " steps from " + currentStep + " to " + (currentStep + presteps));
		 } else {
		 	runsteps=stepStopCrit.getMaximumNumberSteps();
		 }
		 if (solve) {
			thisStartTime = new Date().getTime();
			sim.getSimulationIterator().run();
			logSolveTime(thisStartTime, presteps, "Pre-solve");
		}

		 // Solve steps
		 int presolveEnd = stepStopCrit.getMaximumNumberSteps();
		 if (changeRunIterations) {
			stepStopCrit.setMaximumNumberSteps(presolveEnd + runsteps);
			sim.println("[Benchmark] Solve: running " + runsteps + " steps from " + presolveEnd + " to " + (presolveEnd + runsteps));
		 }
		 if (solve) {
			thisStartTime = new Date().getTime();
			sim.getSimulationIterator().run();
			logSolveTime(thisStartTime, runsteps, "Solve");
		 }
		 
		 // If we're not solving, we don't want to measure the memory usage.
		 if (solve && measureMemory) {
		 	IterationMaximumMemoryReport memRep=getOrMakeMemoryReport();
		 	sim.getSimulationIterator().step(1);
		 	totalTimes.add(new timing(memRep.getReportMonitorValue(),"Memory Used (GiB)"));
		 }
     }
    // end of V commented section


    // Use a run macro given to us
    if (useRunMacro) {
    	try {
			sim.println("Running solve macro: "+runMacro);
			thisStartTime = new Date().getTime();
			new StarScript(sim, new File(runMacro)).play();
			logTime(thisStartTime, "Solve Macro: "+runMacro);
			sim.println("Completed solve macro: "+runMacro);
		} catch (Exception e) {
			sim.println("Failed solve macro: "+runMacro+" because: "+e);
		}
    }

    if (saveFinalSimulations) {
        thisStartTime = new Date().getTime();
        sim.saveState(resolvePath(sim.getSessionDir() + java.io.File.separator + "final.sim"));
        logTime(thisStartTime, "Save final.sim");
    }
    if (saveSimulations) {
        sim.saveState(resolvePath(simDir+simName));
    }


        

        // let's export the scenes before running the post processing script
        // just in case that script creates more scenes which could be quite
        // costly in terms of time. In fact, let's get the list of scenes now
        // then just use that later, in case we want to make changes to it but not
        // necessarily export all.
        //Collection<Scene> allScenes = sim.getSceneManager().getScenes();

	for (String mac:postRunMacro) {
		try {
			sim.println("Running post run macro: "+mac);
			thisStartTime = new Date().getTime();
			new StarScript(sim, new File(mac)).play();
			logTime(thisStartTime, "Macro "+mac);
			sim.println("Completed post run macro: "+mac);
		} catch (Exception e) {
			sim.println("Failed post run macro: "+mac+" because: "+e);
		}
	}

        /* 
if (exportAllScenes) {
            long lStartTime = new Date().getTime();
            for (Scene s : allScenes) {
                s.printAndWait(simDir + sep + simName + "_" + s.getPresentationName() + ".png", 1, 1600, 900);
                // Do we want to put a serial number on the simulation, attach to the image names and
                // store them somewhere centrally for later checking?!
                // Also, do we want to export all plots? Perhaps!
            }
            for (StarPlot p : sim.getPlotManager().getPlots()) {
//            p.printToFile(simDir+sep+simName+"_"+p.getPresentationName()+".png", 1, 1600, 900);
            }
            long lEndTime = new Date().getTime();
            double difference = (lEndTime - lStartTime) / 1000.;
            sim.println("[Timing] sceneExport_elapsedSeconds," + difference);
        }
 */
    
  }
  
  public void useSimDriverWorkFlowRunner() {
  		// WIP
  		// Also: Not supported in v15 of STAR-CCM+
  		sim.println("No Simulation Controller methodology currently implemented.");
//       SimDriverWorkflow wf = ((SimDriverWorkflow) sim.get(SimDriverWorkflowManager.class).getObject("Dynamic_run"));
//       sim.get(SimDriverWorkflowManager.class).setSelectedWorkflow(wf);
//       wf.execute();
//       CumulativeElapsedTimeReport tr = ((CumulativeElapsedTimeReport) sim.getReportManager().getReport("Total Solver Elapsed Time"));
//       sim.println("Total Solver Elapsed Time: "+tr.getReportMonitorValue());
  }
  
  public double logTime(long lStartTime, String stepName) {
      long lEndTime = new Date().getTime();
      double difference = (lEndTime - lStartTime) / 1000.;
      totalTimes.add(new timing(difference,stepName));
      sim.println("[TIMING] "+stepName+" time, s:" + difference + " min: "+(difference/60));
      return difference;
  }
    
  public double logSolveTime(long lStartTime, int iterations, String stepName) {
      long lEndTime = new Date().getTime();
      double difference = (lEndTime - lStartTime) / 1000.;
      double AVGdifference = ((lEndTime - lStartTime) / 1000.)/((double) iterations);
      totalTimes.add(new timing(difference,stepName+" ("+iterations+" iterations)"));
      totalTimes.add(new timing(AVGdifference,stepName+" Average Iteration Time"));
      sim.println("[TIMING] "+stepName+" time, s:" + difference + " min: "+(difference/60));
      return difference;
  }
  
  public void compileTimings() {


	String c=",";
	String caseName = sim.getSessionDir().split(splittingSep)[sim.getSessionDir().split(splittingSep).length-1];
	
	String version = sim.getStarVersion().getString("ReleaseNumber");
    
	int cores = sim.getNumberOfWorkers();
	
	String hosts=sim.getHosts().toString();
	String rank = "";
	for (String m:hosts.split(c)) {
		if (m.contains("'Rank[0]'")) {
			rank = m;
		}
	}
	rank = rank.split("'")[3];
//   	sim.println("sysinfo "+sim.getSystemInformation().asProperties());
    int hostcount=sim.getSystemInformation().getNumberHosts();
	int processes=sim.getSystemInformation().getNumberProcesses();
	// Only relevant in later versions of STAR.
// 	int gpgpus=sim.getSystemInformation().getNumberGpgpus();
	boolean r8=sim.getSystemInformation().isDoublePrecision();
	String uniqueSerialNumber = totalStartTime + "" + cores;
	
    String header = "Run Name, Unique Serial Number, Sim File Name, STAR-CCM+ Version,Number of Cores,Machine 0 Name,Host count,GPGPUs,Double Precision";
    String vals = caseName + c + uniqueSerialNumber + c + simName+".sim"+ c + version + c + cores + c + rank +c+ hostcount+c+"0"+c+r8;


	jsonData.add(new jsonoutput("Run Name","S",caseName));
	jsonData.add(new jsonoutput("Unique Serial Number","N",uniqueSerialNumber));
	jsonData.add(new jsonoutput("Sim File Name","S",simName+".sim"));
	jsonData.add(new jsonoutput("STAR-CCM+ Version","S",version));
	jsonData.add(new jsonoutput("Number of cores","N",Integer.toString(cores)));
	jsonData.add(new jsonoutput("Machine 0 Name","S",rank));
	jsonData.add(new jsonoutput("Host count","N",Integer.toString(hostcount)));
	//jsonData.add(new jsonoutput("GPGPUs","N",0));
	if (r8) jsonData.add(new jsonoutput("Double Precision","S","TRUE"));
	if (!r8) jsonData.add(new jsonoutput("Double Precision","S","FALSE"));


    for (timing t:totalTimes) {
    	header=header+","+t.getName();
    	vals=vals+","+t.getTime();
    	jsonData.add(new jsonoutput(t.getName(),"N",Double.toString(t.getTime())));
    }
    
    ExpressionReport iters=getOrCreateIterationRep();
    if (measureMemory) { // We did an extra step to get the memory consumption, so we'll remove that from the iteration count
    iters=getOrCreateExpressionReport("Iteration_Count", "${Iteration}-1");
    }
    if (exportAllReports==true) {
        header=header+",";
        vals=vals+",";
        Collection<Report> reps = sim.getReportManager().getObjects();
        for (Report r : reps) {
            r.setPresentationName(r.getPresentationName().replaceAll(" ", "_"));
        }
        ArrayList<Report> newReps = new ArrayList();

        sim.println("Exporting reports to disc");

        Collection<Report> allreps = sim.getReportManager().getObjects();
		sim.println("Found "+allreps.size()+" reports.");
        Collection<String> repsName = new TreeSet<>(); // may need a collator: TreeSet<String>(Collator.getInstance(New Locale(languageCode))); Strips out accents, etc.

        Collection<Report> expreps = new ArrayList<>(); // reports to export

        // produce a sorted list (alphabetically) of all reports
        for (Report r : allreps) {
            expreps.add(r); // using tree set object means it's automagically sorted.
            repsName.add(r.getPresentationName());
        }
        sim.println("Sorted reports list has "+expreps.size()+
                " reports with names list also having "+repsName.size()+" reports (these numbers should be the same).");
 
        for (Report r : expreps) {
            // Loop through all reports
            header = header + r.getPresentationName().replace(" ", "_") + c;
            vals = vals + r.getReportMonitorValue() + c;
            // Need to put in an exception here to avoid values such as
            // -1.7976931348623157E308 which breaks json import into DynamoDB.
            if (r.getReportMonitorValue()>1E20 || r.getReportMonitorValue()<-1E20) {
                jsonData.add(new jsonoutput(r.getPresentationName().replace(" ", "_"),"N","0.0"));
            } else {
                jsonData.add(new jsonoutput(r.getPresentationName().replace(" ", "_"),
                    "N",Double.toString(r.getReportMonitorValue())));
            }
        }
    } else {
    	
    	header = header + c + "Final Iteration";
    	vals = vals + c + iters.getReportMonitorValue();
    	jsonData.add(new jsonoutput("Final Iteration","N",Double.toString(iters.getReportMonitorValue())));
    
    }
                        
    sim.println("\n    **************************************************");
    sim.println("    Simulation Wall-timings (Secs): ");
    sim.println(header+"\n"+vals);
    sim.println("    **************************************************");
            
	// write out the timings to .csv file:
	writeTimings(header,vals,exportFile);
	writeTimings(header,vals,masterFileLoc);
	
	if (writeToJSON) writeTimingsToJSON("benchmark.json");
  }
  
  private void writeTimingsToJSON(String filePath) {
  
  
  	boolean fileExists = true;
  	
  	try {
  		BufferedReader br = new BufferedReader(new FileReader(new File(filePath)));
  		br.close();  	
  	} catch (Exception ex) {
  		fileExists = false;
  		sim.println("Output file "+filePath+" doesn't exist so will be created.");
  	}
  	try {
  		BufferedWriter bw = new BufferedWriter(new FileWriter(new File(filePath),fileExists));
  		bw.write("{");
  		bw.newLine();
  		
  		// Try to read in data written out by bash script before submitted job started
        BufferedReader br = new BufferedReader(new FileReader ("simulation_info.csv"));
        String line;
        while( (line = br.readLine() ) != null) {
            bw.write(line);
            bw.newLine();
        }
        br.close();
  		
  		for (jsonoutput j:jsonData) {
  		    bw.write("    \""+j.getName()+"\": {\""+j.getType()+"\": \""+j.getValue()+"\"},");
  		    bw.newLine();
        }
        
        bw.write("    \"pc_version\": {\"S\": \"3.6.1\"}"); // hard code the last value without comma for now
  		bw.newLine();
  		bw.write("}");
  		bw.close();
  	} catch (Exception ex) {
  		sim.println("There was a problem writing to file "+filePath+" because "+ex);
  	}
  
  
  }
  
  private void writeTimings(String header, String output, String filePath) {
  
  	boolean fileExists = true;
  	
  	try {
  		BufferedReader br = new BufferedReader(new FileReader(new File(filePath)));
  		br.close();  	
  	} catch (Exception ex) {
  		fileExists = false;
  		sim.println("Output file "+filePath+" doesn't exist so will be created.");
  	}
  	try {
  		BufferedWriter bw = new BufferedWriter(new FileWriter(new File(filePath),fileExists));
  		
  		bw.write(header);
  		bw.newLine();
  		bw.write(output);
  		bw.newLine();
  		bw.close();
  	} catch (Exception ex) {
  		sim.println("There was a problem writing to file "+filePath+" because "+ex);
  	}
  
  
  }


	public void setMaximumSteps(int maxsteps) {
	
		StepStoppingCriterion stepStoppingCriterion=getOrMakeMaximumStepsCriterion();
		stepStoppingCriterion.getMaximumNumberStepsObject().getQuantity().setValue(maxsteps);
		stepStoppingCriterion.setIsUsed(true);
	}
	
    public StepStoppingCriterion getOrMakeMaximumStepsCriterion() {
        StepStoppingCriterion stepStoppingCriterion = null;
        try {
            stepStoppingCriterion = 
          		((StepStoppingCriterion) sim.getSolverStoppingCriterionManager()
    		      .getSolverStoppingCriterion("Maximum Steps"));
        } catch (Exception ex) {
        	stepStoppingCriterion = 
          		sim.getSolverStoppingCriterionManager()
          		.createSolverStoppingCriterion(StepStoppingCriterion.class);
        }
        return stepStoppingCriterion;
        }
    
    
    
    public int setFixedSteps(int fixedsteps) {
	
		FixedStepsStoppingCriterion fixedStepsStoppingCriterion=getOrMakeFixedStepsStoppingCriterion();
		fixedStepsStoppingCriterion.getFixedStepsObject().getQuantity().setValue(fixedsteps);
	    //fixedStepsStoppingCriterion.getLogicalOption().setSelected(SolverStoppingCriterionLogicalOption.Type.AND);
	    //fixedStepsStoppingCriterion.getLogicalOption().setSelected(SolverStoppingCriterionLogicalOption.Type.OR);
		fixedStepsStoppingCriterion.setIsUsed(true);
		return fixedStepsStoppingCriterion.getStartStep(); // we have an int value here that we can use.
	}
	
    public FixedStepsStoppingCriterion getOrMakeFixedStepsStoppingCriterion() {
        FixedStepsStoppingCriterion fixedStepsStoppingCriterion = null;
        try {
            fixedStepsStoppingCriterion = 
          		((FixedStepsStoppingCriterion) sim.getSolverStoppingCriterionManager()
    		      .getSolverStoppingCriterion("Fixed Steps"));
        } catch (Exception ex) {
        	fixedStepsStoppingCriterion = 
          		sim.getSolverStoppingCriterionManager()
          		.createSolverStoppingCriterion(FixedStepsStoppingCriterion.class);
        }
        return fixedStepsStoppingCriterion;
        }
    
    
    public IterationMaximumMemoryReport getOrMakeMemoryReport() {

    	    IterationMaximumMemoryReport iterationMaximumMemoryReport = 
        		sim.getReportManager().createReport(IterationMaximumMemoryReport.class);
        	iterationMaximumMemoryReport.setUnits(
        		(Units) sim.getUnitsManager().getObject("GiB")); // Default "B", also "GiB", "KiB", "MiB"
        	iterationMaximumMemoryReport.getMemoryReportMetricOption().setSelected(MemoryReportMetricOption.Type.RESIDENT);
        	// Default MemoryReportMetricOption.Type.RESIDENT , but also:
        	// Type.VIRTUAL , Type.VIRTUALHWM (maximum), Type.RESIDENTHWM (High watermark - maximum), Type.GPGPU_RESIDENT
        	iterationMaximumMemoryReport.setSamplingFrequency(50); // default is 50
        	return iterationMaximumMemoryReport;
        }


	public ExpressionReport getOrCreateIterationRep() {
        return getOrCreateExpressionReport("Iteration_Count", "${Iteration}");
    }

	public ExpressionReport getOrCreateExpressionReport(String name) {
        try {
            return (ExpressionReport) sim.getReportManager().getReport(name);
        } catch (Exception e) {
            ExpressionReport exprRep = sim.getReportManager().createReport(ExpressionReport.class);
            exprRep.setPresentationName(name);
            return exprRep;
        }
    }
    
    public ExpressionReport getOrCreateExpressionReport(String name, String def) {
        ExpressionReport exprRep = getOrCreateExpressionReport(name);
        exprRep.setDefinition(def);
        return exprRep;
    }
    
    public void deleteExpressionReport(String name) {
       sim.getReportManager().removeObjects((ExpressionReport) sim.getReportManager().getReport(name));
	}
    

// Not working at the moment:
// public ElementCountReport makeCellCountRep() {
// 
//         ElementCountReport cellCountReport;
//         try {
//             cellCountReport = (ElementCountReport) sim.getReportManager().getReport("Cell_Count");
//         } catch (Exception e) {
//             cellCountReport = sim.getReportManager().createReport(ElementCountReport.class);
//             cellCountReport.setPresentationName("Cell_Count");
//         }
//         cellCountReport.getParts().setQuery(new Query(new CompoundPredicate(CompoundOperator.And, Arrays.asList(new TypePredicate(TypeOperator.Is, Region.class))), Query.STANDARD_MODIFIERS));
//         LatestMeshProxyRepresentation mpr = ((LatestMeshProxyRepresentation) sim.getRepresentationManager().getObject("Latest Surface/Volume"));
//         cellCountReport.setRepresentation(mpr);
//         return cellCountReport;
//     }

  
  public class timing {
        private double time;
        private String name;
        
        public timing(double time, String name) {
            this.time = time;
            this.name = name;
        }
        
        public double getTime() {
            return time;
        }
        public String getName() {
            return name;
        }
        public void setTime(double time) {
            this.time = time;
        }
        public void setName(String name) {
            this.name = name;
        }
    }
    
    /* we're going to specify the values we want to export and json and use bash
    to create the json file, so we can add AWS values to the data too
    */
    public class jsonoutput {
        private String name;
        private String type;
        private String value;
        
        public jsonoutput(String name, String type, String value) {
            this.name = name;
            this.type = type;
            this.value = value;
        }
        
        public String getName() {
            return name;
        }
        public String getType() {
            return type;
        }
        public String getValue() {
            return value;
        }
        public void setName(String name) {
            this.name = name;
        }
        public void setType(String type) {
            this.type = type;
        }
        public void setValue(String value) {
            this.value = value;
        }
    }
  
}

