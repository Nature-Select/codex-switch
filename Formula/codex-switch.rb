class CodexSwitch < Formula
  desc "Keep several Codex accounts side by side and switch between them"
  homepage "https://github.com/Nature-Select/codex-switch"
  url "https://github.com/Nature-Select/codex-switch/releases/download/v1.0.1/codex-switch-1.0.1-macos-universal.tar.gz"
  sha256 "555082395144c25f7abda6551fc670e903974de435a1c1845c243dde9637b233"
  license "MIT"
  version "1.0.1"

  depends_on :macos

  def install
    bin.install "codex-switch"
  end

  test do
    assert_match "codex-switch", shell_output("#{bin}/codex-switch --version")
  end
end
