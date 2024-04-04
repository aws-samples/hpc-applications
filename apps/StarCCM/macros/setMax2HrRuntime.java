// Simcenter STAR-CCM+ macro: setMax2HrRuntime.java
// Written by Simcenter STAR-CCM+ 18.04.001
// This macro limits the simulation to run for a particular wall clock time only.
package macro;

import java.util.*;

import star.common.*;
import star.base.neo.*;
import star.base.report.*;

public class setMax2HrRuntime extends StarMacro {

  public void execute() {
    execute0();
  }

  private void execute0() {

    Simulation sim =
      getActiveSimulation();

    SimulationIteratorTimeReportMonitor simulationIteratorTimeReportMonitor_0 =
      ((SimulationIteratorTimeReportMonitor) sim.getMonitorManager().getMonitor("Total Solver Elapsed Time Monitor"));
      
    Units units_0 =
      ((Units) sim.getUnitsManager().getObject("hr"));



    MonitorIterationStoppingCriterion monitorIterationStoppingCriterion_0 =
      sim.getSolverStoppingCriterionManager().createIterationStoppingCriterion(simulationIteratorTimeReportMonitor_0);

    ((MonitorIterationStoppingCriterionOption) monitorIterationStoppingCriterion_0.getCriterionOption())
    .setSelected(MonitorIterationStoppingCriterionOption.Type.MAXIMUM);

    MonitorIterationStoppingCriterionMaxLimitType monitorIterationStoppingCriterionMaxLimitType_0 =
      ((MonitorIterationStoppingCriterionMaxLimitType) monitorIterationStoppingCriterion_0.getCriterionType());    

    monitorIterationStoppingCriterionMaxLimitType_0.getLimit().setValueAndUnits(2.0, units_0);

    monitorIterationStoppingCriterion_0.setPresentationName("Total Solver Elapsed Time Monitor Criterion InnerIts");



	MonitorIterationStoppingCriterion monitorIterationStoppingCriterion_1 =
      sim.getSolverStoppingCriterionManager().createIterationStoppingCriterion(simulationIteratorTimeReportMonitor_0);

    ((MonitorIterationStoppingCriterionOption) monitorIterationStoppingCriterion_1.getCriterionOption())
    .setSelected(MonitorIterationStoppingCriterionOption.Type.MAXIMUM);

    MonitorIterationStoppingCriterionMaxLimitType monitorIterationStoppingCriterionMaxLimitType_1 =
      ((MonitorIterationStoppingCriterionMaxLimitType) monitorIterationStoppingCriterion_1.getCriterionType());    

    monitorIterationStoppingCriterionMaxLimitType_1.getLimit().setValueAndUnits(2.0, units_0);
    
    monitorIterationStoppingCriterion_1.setInnerIterationCriterion(false);
    
    monitorIterationStoppingCriterion_1.setPresentationName("Total Solver Elapsed Time Monitor Criterion OuterIts");
  }
}