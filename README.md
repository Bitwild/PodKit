# PodKit

[CocoaPods](https://github.com/CocoaPods/CocoaPods) extension for internal project hierarchy adherence. By default CocoaPods will create `Frameworks` and
`Pods` groups in top level of Xcode project, while our conventions would want all dependency shit sitting under `dependency` group.

Solution is to use pre- and post-install hooks to move groups where CocoaPods wants them prior install and back when it's finished. To [my](https://github.com/ianbytchek) big surprise this works very well. PodKit will also patch `.xcconfig` files and include standard [swifteroid/xenomorph](https://github.com/swifteroid/xenomorph) configuration per target type.

Install PodKit as git submodule:

```sh
git submodule add https://github.com/bitwild/podkit dependency/git/podkit
git submodule update --init --recursive
```

Update `Podfile` to include PodKit and add pre- and post-install hooks:

```ruby
require_relative 'git/podkit/source/pod_kit'

pre_install { |installer| PodKit.pre_install(installer) }
post_install { |installer| PodKit.post_install(installer) }

project '…'
target '…' do
  use_frameworks!
  pod '…', '~> 1.0.0'
end
```