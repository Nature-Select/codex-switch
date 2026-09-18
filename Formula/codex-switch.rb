class CodexSwitch < Formula
  desc "Keep several Codex accounts side by side and switch between them"
  homepage "https://github.com/Nature-Select/codex-switch"
  url "https://github.com/Nature-Select/codex-switch/releases/download/v1.1.0/codex-switch-1.1.0-macos-universal.tar.gz"
  sha256 "7b5b17e89ad4b9d2b75134a6e29d0892983f99fad8da9708f8457ac6ce6643c7"
  license "MIT"
  version "1.1.0"

  depends_on :macos

  def install
    bin.install "codex-switch"
  end

  test do
    assert_match "codex-switch", shell_output("#{bin}/codex-switch --version")
  end
end
