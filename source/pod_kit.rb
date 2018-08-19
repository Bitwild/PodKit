require 'cocoapods'

# http://www.rubydoc.info/github/CocoaPods/Xcodeproj/Xcodeproj/Project
# http://www.rubydoc.info/gems/cocoapods/Pod/Installer

# Redefine build phase prefix – we don't want fucking [CP] in front on phases.
class Pod::Installer::UserProjectIntegrator::TargetIntegrator
  remove_const(:BUILD_PHASE_PREFIX)
  BUILD_PHASE_PREFIX = ''.freeze
end

# Override `perform_post_install_actions` in order to move back groups into dependencies.
class Pod::Installer
  alias_method(:perform_post_install_actions_old, :perform_post_install_actions)

  def perform_post_install_actions
    perform_post_install_actions_old
    post_integrate_method
  end

  def post_integrate_method
    return if self.aggregate_targets.empty?
    project = self.aggregate_targets[0].user_project
    dependency_group = project['dependency']
    cocoa_pods_group = dependency_group['CocoaPods'] || dependency_group.new_group('CocoaPods')

    project['Frameworks']&.tap { |group|
      group.name = 'Framework'
      group.move(cocoa_pods_group)
    }

    project['Pods']&.tap { |group|
      group.children.each { |child| child.path = child.path.gsub(/^dependency\//, '') }
      group.name = 'Configuration'
      group.move(cocoa_pods_group)
    }

    cocoa_pods_group&.sort_by_type()
    project.save()
  end
end

# Override `relative_glob` to allow parent file access. Todo: might be a good idea to implement option support.
class Pod::Sandbox::PathList
  alias_method(:relative_glob_old, :relative_glob)

  def relative_glob(patterns, options = {})
    return [] if patterns.empty?

    cache_key = options.merge(:patterns => patterns)
    cached_value = @glob_cache[cache_key]
    return cached_value if cached_value

    dir_pattern = options[:dir_pattern]
    exclude_patterns = options[:exclude_patterns]
    include_dirs = options[:include_dirs]

    list = Array(patterns).flat_map { |pattern| self.root.glob(pattern, File::FNM_CASEFOLD) }

    # Include subdirectory patterns, `- list` ensures no duplicates, not sure if it matters, though…
    list += list.select { |pathname| pathname.directory? }.flat_map { |pathname| pathname.glob(dir_pattern, File::FNM_CASEFOLD) } - list unless dir_pattern.nil?

    # Remove matched directories if option explicitly says so.
    list = list.select { |pathname| !pathname.directory? } if include_dirs === false

    # Convert paths to relative and exclude specified patterns. 
    list = list.map { |pathname| pathname.relative_path_from(self.root) }
    list -= relative_glob(exclude_patterns, { :dir_pattern => '**/*', :include_dirs => include_dirs }) unless exclude_patterns.nil? || exclude_patterns.empty?


    # To debug differences with original method… also comment out caching.
    # old_list = relative_glob_old(patterns, options)
    # missing_list = old_list - list
    # unexpected_list = list - old_list
    # raise "Swizzled implementation has #{missing_list.count} missing and #{unexpected_list} unexpected files compared to original implementation." unless missing_list.empty? && unexpected_list.empty?

    @glob_cache[cache_key] = list

    return list
  end
end

module PodKit

  # We want to keep project structure and store fucking pod groups right there. This involves moving them temporary
  # into root category and moving them back when CocoaPods are done.
  def self.pre_install(installer)
    return if installer.aggregate_targets.empty?
    project = installer.aggregate_targets[0].user_project
    dependency_group = project['dependency']

    (dependency_group['pod-frameworks'] || dependency_group['CocoaPods']['Framework'])&.tap { |group|
      group.name = 'Frameworks'
      group.move(project.main_group)
    }

    (dependency_group['pod-configuration'] || dependency_group['CocoaPods']['Configuration'])&.tap { |group|
      group.children.each { |child| child.path = "dependency/#{child.path}" }
      group.name = 'Pods'
      group.move(project.main_group)
    }

    project.save()
  end

  # Here we include standard xenomorph configuration.
  def self.post_install(installer)
    include_names = {
      'bundle.ui-testing' => 'Test',
      'bundle.unit-test' => 'Test',
      'application' => 'macOS/macOS - Application',
      'framework' => 'macOS/macOS - Framework',
      'library.dynamic' => 'macOS/macOS - Framework',
      'library.static' => 'macOS/macOS - Framework',
      'xpc-service' => 'macOS/macOS - Application'
    }

    # We're interested in pod targets in our project, so we get pods projects and find targets matching 
    # aggregated ones. First must check that target is native – one of our own in the project.
    installer.pods_project.targets.each do |target|

      # This how we did it in version 1.5.3, but with 1.6.0 the API seem to have changed. Leaving for reference.
      # aggregate_target = installer.aggregate_targets.find { |t| t.native_target.uuid == target.uuid }

      aggregate_target = installer.aggregate_targets.find { |t| t.target_definition.label == target.name }
      next if aggregate_target.nil?

      unless aggregate_target.user_target_uuids.count == 1
        puts "PodKit hasn't discovered any UUIDs in aggregate target needed to acquire native target – please contact developer.".red() if aggregate_target.user_target_uuids.count < 1
        puts "PodKit discovered multiple UUIDs in aggregate target, but knows how to handle only one – please contact developer.".red() if aggregate_target.user_target_uuids.count > 1
        exit(1)
      end

      unless (project_target = aggregate_target.user_project.targets.find { |t| t.uuid == aggregate_target.user_target_uuids.first })
        puts "PodKit couldn't find project target using available target UUID." if project_target.nil?
        exit(1)
      end

      next unless (target_configuration_name = include_names[project_target.product_type.gsub(/^com\.apple\.product-type\./, '')])

      target.build_configurations.each do |config|
        next if (config = config.base_configuration_reference).nil?
        include_statement = "#include \"../../../git/xenomorph/source/Target/#{target_configuration_name}.xcconfig\"\n\n"
        config_path = config.real_path
        config_contents = include_statement + File.read(config_path)
        File.open(config_path, 'w') { |fd| fd.write(config_contents) }
      end
    end
  end
end
