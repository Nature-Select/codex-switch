class CodexSwitch < Formula
  desc "Keep several Codex accounts side by side and switch between them"
  homepage "https://github.com/Nature-Select/codex-switch"
  url "https://github.com/Nature-Select/codex-switch/releases/download/v1.3.0/codex-switch-1.3.0-macos-universal.tar.gz"
  sha256 "b627bd771d127b9955abc59bd723c2425ebacf166e5e984c4d8017b6f4bcb310"
  license "MIT"
  version "1.3.0"

  depends_on :macos

  def install
    bin.install "codex-switch"
  end

  test do
    assert_match "codex-switch", shell_output("#{bin}/codex-switch --version")
  end
end
