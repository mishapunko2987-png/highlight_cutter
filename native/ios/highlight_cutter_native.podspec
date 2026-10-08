Pod::Spec.new do |s|
  s.name             = 'highlight_cutter_native'
  s.version          = '0.1.0'
  s.summary          = 'Нативная обработка видео.'
  s.description      = 'Анализ кадров и нарезка клипов на iOS.'
  s.homepage         = 'https://example.com'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Highlight Cutter' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
  s.frameworks = 'AVFoundation', 'CoreImage'
end
