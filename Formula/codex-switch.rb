class CodexSwitch < Formula
  desc "Keep several Codex accounts side by side and switch between them"
  homepage "https://github.com/Nature-Select/codex-switch"
  url "https://github.com/Nature-Select/codex-switch/releases/download/v1.4.0/codex-switch-1.4.0-macos-universal.tar.gz"
  sha256 "f180eef1d648f69017eb15b9727cb370ee7b87967e4407616227aff636531a4a"
  license "MIT"
  version "1.4.0"

  depends_on :macos

  def install
    bin.install "codex-switch"
  end

  test do
    assert_match "codex-switch", shell_output("#{bin}/codex-switch --version")
  end
end
