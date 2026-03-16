require "test_helper"

class Investigations::UrlClassifierTest < ActiveSupport::TestCase
  # --- Accepted: real article URLs ---

  test "accepts typical news article with date and slug" do
    assert_accepted "https://g1.globo.com/economia/noticia/2025/03/11/dolar-fecha-em-alta.ghtml"
  end

  test "accepts article with long slug" do
    assert_accepted "https://www.folha.uol.com.br/mercado/2025/03/governo-anuncia-novas-medidas-economicas.shtml"
  end

  test "accepts article with numeric ID" do
    assert_accepted "https://www.estadao.com.br/politica/artigo/12345"
  end

  test "accepts article with query param ID" do
    assert_accepted "https://portal.stf.jus.br/noticias/verNoticiaDetalhe.asp?idConteudo=123456"
  end

  test "accepts article with three path segments" do
    assert_accepted "https://www.cartacapital.com.br/politica/governo-federal-anuncia-programa/"
  end

  test "accepts article with deep path" do
    assert_accepted "https://veja.abril.com.br/economia/pib-cresce-2-por-cento-em-2025"
  end

  test "accepts government record pages" do
    assert_accepted "https://www.congress.gov/bill/118th-congress/senate-bill/1234"
  end

  test "accepts scientific paper URLs" do
    assert_accepted "https://pubmed.ncbi.nlm.nih.gov/39876543/"
  end

  test "accepts arxiv paper" do
    assert_accepted "https://arxiv.org/abs/2503.12345"
  end

  test "accepts root with query parameters" do
    assert_accepted "https://fred.stlouisfed.org?series_id=GDP"
  end

  test "accepts PDF document URLs" do
    assert_accepted "https://www.bcb.gov.br/content/publicacoes/relatorio-inflacao-2025.pdf"
  end

  # --- Rejected: social media ---

  test "rejects twitter URL" do
    assert_rejected "https://twitter.com/someone/status/123456", :social_media
  end

  test "rejects x.com URL" do
    assert_rejected "https://x.com/someone/status/123456", :social_media
  end

  test "rejects instagram URL" do
    assert_rejected "https://www.instagram.com/p/ABC123/", :social_media
  end

  test "rejects facebook URL" do
    assert_rejected "https://www.facebook.com/page/posts/123", :social_media
  end

  test "rejects reddit URL" do
    assert_rejected "https://www.reddit.com/r/worldnews/comments/abc/title/", :social_media
  end

  test "rejects youtube URL" do
    assert_rejected "https://www.youtube.com/watch?v=abc123", :social_media
  end

  test "rejects tiktok URL" do
    assert_rejected "https://www.tiktok.com/@user/video/123", :social_media
  end

  test "rejects linkedin URL" do
    assert_rejected "https://www.linkedin.com/posts/user-123", :social_media
  end

  test "rejects telegram URL" do
    assert_rejected "https://t.me/channel/123", :social_media
  end

  # --- Rejected: e-commerce ---

  test "rejects amazon product URL" do
    assert_rejected "https://www.amazon.com/dp/B09V3KXJPB", :ecommerce
  end

  test "rejects amazon.com.br URL" do
    assert_rejected "https://www.amazon.com.br/dp/B09V3KXJPB", :ecommerce
  end

  test "rejects mercadolivre URL" do
    assert_rejected "https://www.mercadolivre.com.br/produto-exemplo/p/MLB123", :ecommerce
  end

  test "rejects shopee URL" do
    assert_rejected "https://shopee.com.br/product/123/456", :ecommerce
  end

  test "rejects generic ecommerce path on unknown host" do
    assert_rejected "https://lojadoze.com.br/product/smartphone-xyz", :ecommerce
  end

  test "rejects checkout path" do
    assert_rejected "https://somestore.com/checkout/step1", :ecommerce
  end

  # --- Rejected: search engines ---

  test "rejects google search URL" do
    assert_rejected "https://www.google.com/search?q=news+article", :search_engine
  end

  test "rejects bing URL" do
    assert_rejected "https://www.bing.com/search?q=test", :search_engine
  end

  # --- Rejected: index/homepage ---

  test "rejects bare homepage" do
    assert_rejected "https://g1.globo.com", :index_page
  end

  test "rejects homepage with trailing slash" do
    assert_rejected "https://www.folha.uol.com.br/", :index_page
  end

  test "accepts single section path (post-fetch filtering handles these)" do
    assert_accepted "https://g1.globo.com/economia"
  end

  test "accepts section path with trailing slash (post-fetch filtering handles these)" do
    assert_accepted "https://www.folha.uol.com.br/mercado/"
  end

  test "accepts two short category segments (post-fetch filtering handles these)" do
    assert_accepted "https://g1.globo.com/economia/mercado"
  end

  # --- Rejected: non-content ---

  test "rejects zip file URL" do
    assert_rejected "https://example.com/files/archive.zip", :non_content
  end

  test "rejects executable URL" do
    assert_rejected "https://example.com/download/setup.exe", :non_content
  end

  test "rejects video file URL" do
    assert_rejected "https://example.com/media/video.mp4", :non_content
  end

  # --- Formerly rejected listing pages now pass pre-fetch (post-fetch ArticleDetector handles these) ---

  test "accepts tag page (post-fetch filtering)" do
    assert_accepted "https://g1.globo.com/tag/economia/"
  end

  test "accepts author page (post-fetch filtering)" do
    assert_accepted "https://www.folha.uol.com.br/author/joao-silva/"
  end

  test "accepts category page (post-fetch filtering)" do
    assert_accepted "https://news.example.com/brasil/category/politica/"
  end

  test "accepts archive page (post-fetch filtering)" do
    assert_accepted "https://example.com/blog/archive/2025/"
  end

  test "accepts paginated listing (post-fetch filtering)" do
    assert_accepted "https://example.com/noticias/page/3/"
  end

  test "accepts autor page in Portuguese (post-fetch filtering)" do
    assert_accepted "https://example.com/autor/maria-silva/artigos"
  end

  test "accepts topics page (post-fetch filtering)" do
    assert_accepted "https://example.com/topics/climate-change/"
  end

  # --- Rejected: non-article hosts ---

  test "rejects falabr.cgu.gov.br" do
    assert_rejected "https://falabr.cgu.gov.br/publico/Manifestacao/SelecionarTipoManifestacao.aspx", :non_article_host
  end

  test "rejects sidra subdomain" do
    assert_rejected "https://sidra.ibge.gov.br/tabela/1621", :non_article_host
  end

  test "rejects landing page subdomain" do
    assert_rejected "https://lps.marketing.com/promo", :non_article_host
  end

  test "rejects static CDN subdomain" do
    assert_rejected "https://static.example.com/assets/image.jpg", :non_article_host
  end

  test "rejects acesso.gov.br" do
    assert_rejected "https://acesso.gov.br/login", :non_article_host
  end

  test "rejects wa.me link" do
    assert_rejected "https://wa.me/5511999999999", :non_article_host
  end

  # --- Edge cases ---

  test "accepts two segments when one is a long slug" do
    assert_accepted "https://revistaoeste.com/politica/governo-anuncia-reforma-tributaria-para-2026"
  end

  test "accepts path with article segment" do
    assert_accepted "https://example.com/news/article/breaking-story-details"
  end

  test "accepts path with noticia segment" do
    assert_accepted "https://example.com/noticia/detalhes-da-historia"
  end

  private

  def assert_accepted(url)
    assert Investigations::UrlClassifier.call(url), "Expected #{url} to be accepted"
  end

  def assert_rejected(url, expected_key)
    error = assert_raises(Investigations::UrlClassifier::RejectedUrlError) do
      Investigations::UrlClassifier.call(url)
    end
    assert_equal expected_key, error.rejection_key, "Expected rejection key #{expected_key} but got #{error.rejection_key} for #{url}"
  end
end
