require 'cocoapods'
require 'xcodeproj'

# http://www.rubydoc.info/github/CocoaPods/Xcodeproj/Xcodeproj/Project
# http://www.rubydoc.info/gems/cocoapods/Pod/Installer

module PodKit
  # User-friendly target types for including configurations.
  # @see https://github.com/CocoaPods/Xcodeproj/blob/d9a1ccb053bbfca061fb2c387ca22fadc683c4ed/lib/xcodeproj/constants.rb#L141-L162
  PRODUCT_TYPES = {
    'bundle.ui-testing' => :test,
    'bundle.unit-test' => :test,
    'application' => :application,
    'tool' => :cli,
    'framework' => :framework,
    'library.dynamic' => :dynamic_library,
    'library.static' => :static_library,
    'xpc-service' => :xpc
  }

  # Customizable CocoaPods phase prefixes.
  PHASE_PREFIXES = {
    :build_phase => :BUILD_PHASE_PREFIX,
    :user_build_phase => :USER_BUILD_PHASE_PREFIX
  }
end

class Pod::Podfile
  # @return [Hash<Symbol, String>] Custom product configuration.
  attr_accessor :product_configurations

  # @return [String] Custom CocoaPods categories location, when specified `Frameworks` and `Pods` CocoaPods groups are moved there.
  attr_accessor :group_path

  # Sets the base configuration to be included for the given product type.
  # @param [PodKit::PRODUCT_TYPES] product_type
  # @param [String] path Configuration file path relative to the project.
  def configuration(product_type, path)
    raise "Invalid product type #{product_type.inspect}, valid values: #{PodKit::PRODUCT_TYPES.values.uniq.map { |p| p.inspect }.join(", ")}" unless PodKit::PRODUCT_TYPES.has_value? product_type
    self.product_configurations = {} if product_configurations.nil?
    self.product_configurations[product_type] = path
  end

  # Sets the "stash" location for CocoaPods `Frameworks` and `Pods` groups, so that they are not stored in the root of the project.
  def group(path)
    self.group_path = path
  end

  # Sets the custom CocoaPods phase prefix. Note, that phase prefixes should be different, otherwise CocoaPods will confuse
  # them and remove phases with build prefixes when processes user-build ones.
  # @param [PodKit::PHASE_PREFIXES] phase
  # @param [String] new_prefix New prefix.
  def prefix(phase, new_prefix)
    raise "Invalid phase prefix #{phase.inspect}, valid values: #{PodKit::PHASE_PREFIXES.keys.uniq.map { |p| p.inspect }.join(", ")}" unless PodKit::PHASE_PREFIXES.has_key? phase
    Pod::Installer::UserProjectIntegrator::TargetIntegrator.const_set(PodKit::PHASE_PREFIXES[phase], new_prefix.freeze)
  end
end

# Override `perform_post_install_actions` in order to move back groups into dependencies.
class Pod::Installer
  alias_method(:perform_post_install_actions_old, :perform_post_install_actions)

  def perform_post_install_actions
    perform_post_install_actions_old
    PodKit.post_install_groups(self.podfile, self.aggregate_targets[0].user_project) unless self.aggregate_targets.empty?
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
  require 'pathname'

  # Moves standard CocoaPods groups from the stash location.
  # @param [Pod::Podfile] podfile
  # @param [Xcodeproj::Project] project
  def self.pre_install_groups(podfile, project)
    parent_group = podfile.group_path&.then { |path| project.main_group.find_subpath(path, true) }
    return if parent_group.nil?

    # The `pod-framework` directory is stored at `CocoaPods/Framework`. Check the base name 
    parent_group['Framework']&.tap { |group|
      group.name = 'Frameworks'
      group.move(project.main_group)
    }

    parent_group['Configuration']&.tap { |group|
      group.name = 'Pods'
      group.move(project.main_group)
      group.path = parent_group.path
    }

    project.save()
  end

  # Moves standard CocoaPods groups to the stash location.
  # @param [Pod::Podfile] podfile
  # @param [Xcodeproj::Project] project
  def self.post_install_groups(podfile, project)
    parent_group = podfile.group_path&.then { |path| project.main_group.find_subpath(path, true) }
    return if parent_group.nil?

    project['Frameworks']&.tap { |group|
      group.name = 'Framework'
      group.move(parent_group)
    }

    project['Pods']&.tap { |group|
      group.name = 'Configuration'
      group.path = nil
      group.children.each { |child| child.path = Pathname.new(child.real_path).relative_path_from(parent_group.real_path).to_path }
      group.move(parent_group)
    }

    parent_group.sort_by_type()
    project.save()
  end

  # We want to keep project structure and store fucking pod groups right there. This involves moving them temporary
  # into root category and moving them back when CocoaPods is done.
  def self.pre_install(installer)
    self.pre_install_groups(installer.podfile, installer.aggregate_targets[0].user_project) unless installer.aggregate_targets.empty?
  end

  # Here we include the provided configurations for configured product types.
  def self.post_install(installer)
    product_configurations = installer.podfile.product_configurations
    return if product_configurations.nil? || product_configurations.empty?

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

      next unless (configuration_include = product_configurations[PodKit::PRODUCT_TYPES[project_target.product_type.gsub(/^com\.apple\.product-type\./, '')]])

      target.build_configurations.each do |config|
        next if (config = config.base_configuration_reference).nil?
        project_path = project_target.project.project_dir
        config_path = Pathname.new(config.real_path)
        include_statement = "#include \"#{project_path.relative_path_from(config_path.parent)}/#{configuration_include}\"\n\n"
        config_contents = include_statement + config_path.read()
        config_path.write(config_contents)
      end
    end
  end
end
