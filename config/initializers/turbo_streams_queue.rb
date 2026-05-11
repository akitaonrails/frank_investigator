# Route Turbo Stream broadcasts to a dedicated `realtime` queue so a burst of
# UI refreshes (especially the one that accumulates while workers are paused
# during a deploy) can never starve the worker pool that handles actual
# investigation jobs on `default`.
Rails.application.config.to_prepare do
  Turbo::Streams::BroadcastStreamJob.queue_as :realtime if defined?(Turbo::Streams::BroadcastStreamJob)
end
