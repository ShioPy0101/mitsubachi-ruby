namespace :db do
  task :validate_production_database_config do
    next unless Rails.env.production?

    ProductionDatabaseConfigValidator.validate!
  end
end

Rake::Task["db:migrate"].enhance([ "db:validate_production_database_config" ])
