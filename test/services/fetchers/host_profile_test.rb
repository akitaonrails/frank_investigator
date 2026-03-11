require "test_helper"

class Fetchers::HostProfileTest < ActiveSupport::TestCase
  test "returns high budget for g1.globo.com" do
    profile = Fetchers::HostProfile.for("https://g1.globo.com/economia/noticia/2025/03/11/example.ghtml")
    assert_equal 25_000, profile[:budget]
  end

  test "returns elevated budget for folha.uol.com.br" do
    profile = Fetchers::HostProfile.for("https://folha.uol.com.br/mercado/article/123")
    assert_equal 15_000, profile[:budget]
  end

  test "returns elevated budget for infomoney" do
    profile = Fetchers::HostProfile.for("https://infomoney.com.br/investimentos/article")
    assert_equal 20_000, profile[:budget]
  end

  test "returns default budget for unknown host" do
    profile = Fetchers::HostProfile.for("https://unknown-news-site.com/article")
    assert_equal 8_000, profile[:budget]
  end

  test "handles invalid URI gracefully" do
    profile = Fetchers::HostProfile.for("not a valid url")
    assert_equal 8_000, profile[:budget]
  end

  test "returns budget for bloomberg" do
    profile = Fetchers::HostProfile.for("https://bloomberg.com/news/articles/test")
    assert_equal 20_000, profile[:budget]
  end
end
