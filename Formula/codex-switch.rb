class CodexSwitch < Formula
  desc "Keep several Codex accounts side by side and switch between them"
  homepage "https://github.com/Nature-Select/codex-switch"
  url "https://github.com/Nature-Select/codex-switch/releases/download/v1.2.0/codex-switch-1.2.0-macos-universal.tar.gz"
  sha256 "b823ca6f6dbd00936009af0a203adb869f943139c3a53bee1985751bcb3b1087"
  license "MIT"
  version "1.2.0"

  depends_on :macos

  def install
    bin.install "codex-switch"
  end

  test do
    assert_match "codex-switch", shell_output("#{bin}/codex-switch --version")
  end
end
