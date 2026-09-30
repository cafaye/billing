Rails.application.routes.draw do
  # Health probes used by Docker/Kamal, the load balancer and uptime monitors.
  # Infrastructure, not contract surface: they are not in `cafaye.yml`'s
  # `exposes`, they take no query parameters, and no client parses them.
  get "healthz" => "health#show", as: :healthz
  get "readyz" => "health#ready", as: :readyz

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # The API. `/v1` is the API version and changes only for a breaking change,
  # which means a new prefix alongside this one — never this one mutated in
  # place (core's openapi-conventions.md).
  scope "/v1", module: :v1 do
    resources :customers, only: %i[index create show update]

    # `plans` is spelled out rather than generated, because the two lookups are
    # addressed differently on purpose: read by slug, write by id. See
    # V1::PlansController.
    get "plans", to: "plans#index"
    post "plans", to: "plans#create"
    get "plans/:slug", to: "plans#show"
    patch "plans/:id", to: "plans#update"
  end

  # Where `config.exceptions_app = routes` sends a response Rails raised rather
  # than one a controller rendered, so a 404 on an unknown path and a 500 on an
  # unhandled bug are problem+json too.
  match "/404", to: "errors#not_found", via: :all, as: :not_found_page
  match "/422", to: "errors#unprocessable_entity", via: :all, as: :unprocessable_entity_page
  match "/500", to: "errors#internal_server_error", via: :all, as: :internal_server_error_page
  match "/503", to: "errors#service_unavailable", via: :all, as: :service_unavailable_page
end
