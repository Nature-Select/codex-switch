class CodexSwitch < Formula
  desc "Keep several Codex accounts side by side and switch between them"
  homepage "https://github.com/Nature-Select/codex-switch"
  url "https://github.com/Nature-Select/codex-switch/releases/download/v1.0.0/codex-switch-1.0.0-macos-universal.tar.gz"
  sha256 "4a5d2c8b75f1a898585bbe757632517cb64fdccaaedd9d6aa9494cdf7b10ce6a"
  license "MIT"
  version "1.0.0"

  depends_on :macos

  def install
    bin.install "codex-switch"
  end

  test do
    assert_match "codex-switch", shell_output("#{bin}/codex-switch --version")
  end
end
