module Pipeline
  # Checks if a set of parallel pipeline steps have all completed.
  # Used for fan-out/fan-in patterns where multiple independent jobs
  # run in parallel and the next step should only start when all finish.
  class ParallelConvergence
    def self.all_completed?(investigation, step_names)
      step_map = investigation.pipeline_steps.where(name: step_names).index_by(&:name)
      step_names.all? { |name| step_map[name]&.completed? }
    end
  end
end
