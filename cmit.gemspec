require 'rake'

Gem::Specification.new do |s|
  s.name        = 'cmit'
  s.version     = '0.1.0'
  s.date        = '2015-05-29'
  s.summary     = "Git commit utility"
  s.description = <<-EOS
    Performs a git commit after allowing user to edit commit message, and verifying it contains an issue number
EOS

  s.authors     = ["Jeff Sember"]
  s.email       = 'jpsember@gmail.com'
  s.files = FileList['lib/**/*.rb',
                      'bin/*',
                      '[A-Z]*',
                      ]
  s.executables << 'cmit'
  s.add_runtime_dependency 'js_base', '>= 1.0.1'

  s.homepage = 'http://www.cs.ubc.ca/~jpsember'
  s.license     = 'MIT'
end
