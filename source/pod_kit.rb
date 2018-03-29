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
    project = self.aggregate_targets[0].user_project

    project['Frameworks']&.tap { |group|
      group.name = 'pod-frameworks'
      group.move(project['dependency'])
    }

    project['Pods']&.tap { |group|
      group.children.each { |child| child.path = child.path.gsub(/^dependency\//, '') }
      group.name = 'pod-configuration'
      group.move(project['dependency'])
    }

    project['dependency']&.sort_by_type()
    project.save()
  end
end

module PodKit

  # We want to keep project structure and store fucking pod groups right there. This involves moving them temporary
  # into root category and moving them back when CocoaPods are done.
  def self.pre_install(installer)
    project = installer.aggregate_targets[0].user_project

    project['dependency']['pod-frameworks']&.tap { |group|
      group.name = 'Frameworks'
      group.move(project.main_group)
    }

    project['dependency']['pod-configuration']&.tap { |group|
      group.children.each { |child| child.path = "dependency/#{child.path}" }
      group.name = 'Pods'
      group.move(project.main_group)
    }

    project.save()
  end

  # Here we include standard xenomorph configuration.
  def self.post_install(installer)
    include_names = {
      'bundle.unit-test' => 'Test',
      'application' => 'macOS/macOS - Application',
      'framework' => 'macOS/macOS - Framework',
      'library.dynamic' => 'macOS/macOS - Framework',
      'library.static' => 'macOS/macOS - Framework',
    }

    installer.pods_project.targets.each do |target|

      # First must check that target is native – one of our own in the project.
      # Find project target.

      aggregate_target = installer.aggregate_targets.find { |t| t.native_target.uuid == target.uuid }
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
        include_statement = "#include \"../../../git/xenomorph/source/Target/#{target_configuration_name}.xcconfig\"\n\n"
        config_path = config.base_configuration_reference.real_path
        config_contents = include_statement + File.read(config_path)
        File.open(config_path, 'w') { |fd| fd.write(config_contents) }
      end
    end
  end
end
