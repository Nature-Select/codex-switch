class CodexSwitch < Formula
  desc "Keep several Codex accounts side by side and switch between them"
  homepage "https://github.com/Nature-Select/codex-switch"
  url "https://github.com/Nature-Select/codex-switch/releases/download/v1.1.1/codex-switch-1.1.1-macos-universal.tar.gz"
  sha256 "e0c2d52fdddda0de5f72e260c1e5f152ebc4475d6869d42397cab8e1fbf663fa"
  license "MIT"
  version "1.1.1"

  depends_on :macos

  def install
    bin.install "codex-switch"
  end

  test do
    assert_match "codex-switch", shell_output("#{bin}/codex-switch --version")
  end
end
