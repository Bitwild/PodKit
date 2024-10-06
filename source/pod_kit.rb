require 'cocoapods'
require 'xcodeproj'


# http://www.rubydoc.info/github/CocoaPods/Xcodeproj/Xcodeproj/Project
# http://www.rubydoc.info/gems/cocoapods/Pod/Installer


module PodKit
  # User-friendly target types for including configurations, see for details:
  # https://github.com/CocoaPods/Xcodeproj/blob/a01324ec89e76c54dbf146cd9511b65bbebe5e7b/lib/xcodeproj/constants.rb#L152-L174
  PRODUCT_TYPES = {
    'bundle.ui-testing' => :test,
    'bundle.unit-test' => :test,
    'application' => :application,
    'tool' => :cli,
    'framework' => :framework,
    'library.dynamic' => :dynamic_library,
    'library.static' => :static_library,
    'xpc-service' => :xpc,
  }

  # Customizable CocoaPods build phase prefixes.
  INTEGRATION_STYLE = {
    # Combined name delimiter for generated support files, default is `-`.
    :naming_delimiter => nil,
    # Prefix for CocoaPods build phases, default is '[CP] ', changed directly on Pod::Installer::UserProjectIntegrator::TargetIntegrator.
    :build_phase_prefix => :BUILD_PHASE_PREFIX,
    # Prefix for CocoaPods user build phases, default is '[CP-User] ', changed directly on Pod::Installer::UserProjectIntegrator::TargetIntegrator.
    :user_build_phase_prefix => :USER_BUILD_PHASE_PREFIX,
  }
end

class Pod::Podfile
  # @return [Hash<Symbol, String>] Custom product configuration.
  attr_accessor :product_configurations

  # @return [String] Custom CocoaPods categories location, when specified `Frameworks` and `Pods` CocoaPods groups are moved there.
  attr_accessor :group_path

  # @return [Hash<String, String>] Custom library force-loads, see `force_load` for details.
  attr_accessor :force_loads

  # @return [Hash<String, String>] Custom name delimiter (default is `-`) to use for naming generated support files.
  attr_accessor :style

  # Sets the base configuration to be included for the given product type.
  # @param [PodKit::PRODUCT_TYPES] product_type Target product type.
  # @param [String] path *.xcconfig file path relative to the Xcode project.
  # @example
  #   configuration :application, 'accessory/configuration/macOS - Application.xcconfig'
  def configuration(product_type, path)
    raise "Invalid product type #{product_type.inspect}, valid values: #{PodKit::PRODUCT_TYPES.values.uniq.map { |p| p.inspect }.join(", ")}" unless PodKit::PRODUCT_TYPES.has_value? product_type
    self.product_configurations = {} if self.product_configurations.nil?
    self.product_configurations[product_type] = path
  end

  # Tells CocoaPods to use `-force_load` instead of `-ObjC` linker flag for the specified library from the provided path. This is needed
  # when using CocoaPods with Swift Package Manager – CocoaPods adds `-ObjC` flag and it messes things up. See relevant discussion:
  # https://github.com/CocoaPods/CocoaPods/issues/712#issuecomment-38795037
  # @param [String] library
  # @param [String] path
  # @example
  #   force_load 'crypto', '${PROJECT_DIR}/dependency/Private/OpenSSL/lib/libcrypto.a'
  def force_load(library, path)
    self.force_loads = {} if self.force_loads.nil?
    self.force_loads[library] = path
  end

  # Sets the "stash" location for CocoaPods `Frameworks` and `Pods` groups, so that they are not stored in the root of the project.
  # @param [String] new_path The new location relative to the Xcode project.
  # @example
  #   group 'dependency/CocoaPods'
  def group(new_path)
    self.group_path = new_path
  end

  # Sets the custom naming delimiter for CocoaPods-generated support files (configurations, frameworks, etc.)
  # Sets the custom CocoaPods build phase prefix. Note, that phase prefixes should be different, otherwise CocoaPods will confuse
  # them and remove phases with build prefixes when processes user-build ones.
  # @param [PodKit::INTEGRATION_STYLE] style The new delimiter.
  # @param [String] new_value
  # @example
  #   pretty :naming_delimiter, ' - '
  def pretty(style, new_value)
    raise "Invalid #{style.inspect} style, supported values: #{PodKit::INTEGRATION_STYLE.keys.uniq.map { |p| p.inspect }.join(", ")}" unless PodKit::INTEGRATION_STYLE.has_key? style
    if style == :naming_delimiter
      PodKit::INTEGRATION_STYLE[style] = new_value
    else
      Pod::Installer::UserProjectIntegrator::TargetIntegrator.send(:remove_const, PodKit::INTEGRATION_STYLE[style])
      Pod::Installer::UserProjectIntegrator::TargetIntegrator.const_set(PodKit::INTEGRATION_STYLE[style], new_value.freeze)
    end
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

    # The `pod-framework` directory is stored at `CocoaPods/Framework`.
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
    force_loads = installer.podfile.force_loads
    product_configurations = installer.podfile.product_configurations
    return if (force_loads.nil? || force_loads.empty?) && (product_configurations.nil? || product_configurations.empty?)

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

      target.build_configurations.each do |config|
        next if (config = config.base_configuration_reference).nil?
        project_path = project_target.project.project_dir
        config_path = Pathname.new(config.real_path)
        config_contents = config_path.read()

        # Include configuration.
        if (configuration_include = product_configurations&.[](PodKit::PRODUCT_TYPES[project_target.product_type.gsub(/^com\.apple\.product-type\./, '')]))
          config_contents = "#include \"#{project_path.relative_path_from(config_path.parent)}/#{configuration_include}\"\n\n" + config_contents
        end

        # Replace `-ObjC` with `-force_load`.
        unless force_loads.nil? or force_loads.empty?
          config_contents.gsub!(/^(OTHER_LDFLAGS = )(.*-ObjC.*)$/) { "#{$1}#{force_loads.reduce($2.gsub(/\s*-ObjC\s*/, ' ')) { |f, (k, v)| f.gsub(/-(l|framework )\"#{k}\"/) { |m| "#{m} -force_load \"#{v}\"" } }}" }
        end

        config_path.write(config_contents)
      end
    end
  end
end


# 🦍 Heavy monkey-patching CocoaPods starts below… with some stuff we can just use standard hooks – other's rely on the actual swizzling.
# TODO: I'm guessing some monkey-patching can be re-implemented via standard hooks… but it feels like it might be an overkill.


class Pod::Target
  alias_method(:original_xcconfig_path, :xcconfig_path)
  def xcconfig_path(variant = nil)
    return original_xcconfig_path(variant) if variant.nil? || (delimiter = PodKit::INTEGRATION_STYLE[:naming_delimiter]).nil?
    support_files_dir + "#{label}#{delimiter}#{variant.to_s.gsub(File::SEPARATOR, delimiter)}.xcconfig"
  end

  alias_method(:original_framework_name, :framework_name)
  def framework_name
    return original_framework_name if PodKit::INTEGRATION_STYLE[:naming_delimiter].nil?
    "#{label}.framework"
  end

  alias_method(:original_product_name, :product_name)
  def product_name
    return original_product_name if PodKit::INTEGRATION_STYLE[:naming_delimiter].nil?
    if build_as_framework?
      framework_name
    else
      static_library_name
    end
  end

  alias_method(:original_product_basename, :product_basename)
  def product_basename
    return original_product_basename if PodKit::INTEGRATION_STYLE[:naming_delimiter].nil?
    label
  end
end

class Pod::Podfile::TargetDefinition
  alias_method(:original_label, :label)
  def label
    return original_label if (delimiter = PodKit::INTEGRATION_STYLE[:naming_delimiter]).nil?
    @label ||= if root? && name == 'Pods'
      original_label
    elsif exclusive? || parent.nil?
      "Pods#{delimiter}#{name}"
    else
      "#{parent.label}#{delimiter}#{name}"
    end
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

class Pod::Installer::Xcode::PodsProjectGenerator::AggregateTargetInstaller
  alias_method(:original_custom_build_settings, :custom_build_settings)
  def custom_build_settings
    return original_custom_build_settings if PodKit::INTEGRATION_STYLE[:naming_delimiter].nil?
    settings = original_custom_build_settings
    settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
    settings
  end
end

# Override `relative_glob` to allow parent file access. TODO: might be a good idea to implement option support.
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
    # raise "Monkey-patched implementation has #{missing_list.count} missing and #{unexpected_list} unexpected files compared to original implementation." unless missing_list.empty? && unexpected_list.empty?

    @glob_cache[cache_key] = list
    list
  end
end
