class CodexSwitch < Formula
  desc "Keep several Codex accounts side by side and switch between them"
  homepage "https://github.com/Nature-Select/codex-switch"
  url "https://github.com/Nature-Select/codex-switch/releases/download/v1.4.1/codex-switch-1.4.1-macos-universal.tar.gz"
  sha256 "8807c035169cfd2fc2a92b98b8f40ea52a93b0c6c46cacfe1a46fb4cb06cf543"
  license "MIT"
  version "1.4.1"

  depends_on :macos

  def install
    bin.install "codex-switch"
  end

  test do
    assert_match "codex-switch", shell_output("#{bin}/codex-switch --version")
  end
end
