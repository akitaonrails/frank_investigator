Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  mount MissionControl::Jobs::Engine, at: "/jobs"

  resources :error_reports, only: [ :index, :show ] do
    collection { delete :destroy_all }
  end

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # REST API — bearer token auth via FRANK_AUTH_SECRET
  namespace :api do
    resources :investigations, only: [ :create ]
  end

  # Public report pages — read-only, no auth required
  resources :investigations, only: [ :show ] do
    member do
      get :graph_data
    end
  end

  # Static pages — public, no auth
  get "terms" => "pages#terms", as: :terms

  # Submission form — basic auth via FRANK_AUTH_SECRET
  root "investigations#home"
end
