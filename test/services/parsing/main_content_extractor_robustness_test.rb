require "test_helper"

class Parsing::MainContentExtractorRobustnessTest < ActiveSupport::TestCase
  test "strips noisy sidebar with mostly links" do
    html = <<~HTML
      <html><body>
        <article>
          <p>This is the main article content about an important topic that spans multiple sentences and has significant length for testing purposes.</p>
          <p>Another paragraph with more relevant content about the investigation findings.</p>
          <div class="sidebar related">
            <a href="/1">Trending story one</a>
            <a href="/2">Trending story two</a>
            <a href="/3">Trending story three</a>
            <a href="/4">Trending story four</a>
            <a href="/5">Trending story five</a>
          </div>
        </article>
      </body></html>
    HTML

    result = Parsing::MainContentExtractor.call(html:, url: "https://example.com/test")
    assert_includes result.body_text, "main article content"
    refute_includes result.body_text, "Trending story"
  end

  test "strips trending list inside article" do
    html = <<~HTML
      <html><body>
        <article>
          <p>The government released new economic data showing growth in all sectors.</p>
          <p>Experts say this trend is expected to continue throughout the year.</p>
          <ul class="trending most-read">
            <li><a href="/a">Most read article A</a></li>
            <li><a href="/b">Most read article B</a></li>
            <li><a href="/c">Most read article C</a></li>
          </ul>
        </article>
      </body></html>
    HTML

    result = Parsing::MainContentExtractor.call(html:, url: "https://example.com/test")
    assert_includes result.body_text, "economic data"
    refute_includes result.body_text, "Most read article"
  end

  test "removes comment section" do
    html = <<~HTML
      <html><body>
        <article>
          <p>Important news article about policy changes affecting millions of citizens across the country.</p>
          <p>Officials confirmed the policy will take effect next month after review.</p>
        </article>
        <div id="comments">
          <p>User123: I disagree with this article entirely!</p>
          <p>Reader456: Great reporting on this topic.</p>
        </div>
      </body></html>
    HTML

    result = Parsing::MainContentExtractor.call(html:, url: "https://example.com/test")
    assert_includes result.body_text, "policy changes"
    refute_includes result.body_text, "User123"
  end

  test "removes disqus thread" do
    html = <<~HTML
      <html><body>
        <article>
          <p>Detailed analysis of market conditions shows continued volatility in the financial sector.</p>
        </article>
        <div id="disqus_thread">
          <p>Comment thread loading...</p>
        </div>
      </body></html>
    HTML

    result = Parsing::MainContentExtractor.call(html:, url: "https://example.com/test")
    refute_includes result.body_text, "Comment thread"
  end

  test "extracts content from Brazilian portal using materia-conteudo" do
    html = <<~HTML
      <html><body>
        <div class="materia-conteudo">
          <p>O governo anunciou novas medidas econômicas para estimular o crescimento do PIB nacional.</p>
          <p>Segundo o ministro da Economia, as medidas entrarão em vigor no próximo trimestre.</p>
        </div>
        <div class="sidebar related-articles">
          <a href="/1">Matéria relacionada um</a>
          <a href="/2">Matéria relacionada dois</a>
        </div>
      </body></html>
    HTML

    result = Parsing::MainContentExtractor.call(html:, url: "https://g1.globo.com/test")
    assert_includes result.body_text, "medidas econômicas"
  end

  test "extracts content from Folha layout using content-text" do
    html = <<~HTML
      <html><body>
        <div class="content-text">
          <p>Pesquisa indica que a maioria dos brasileiros aprova as reformas propostas pelo governo federal.</p>
          <p>Os dados foram coletados em todas as regiões do país durante o mês de fevereiro.</p>
        </div>
      </body></html>
    HTML

    result = Parsing::MainContentExtractor.call(html:, url: "https://folha.uol.com.br/test")
    assert_includes result.body_text, "reformas propostas"
  end

  test "removes social share widgets" do
    html = <<~HTML
      <html><body>
        <article>
          <p>A comprehensive report on climate change impacts across South American ecosystems was released today.</p>
        </article>
        <div class="social-share">
          <a href="#">Share on Twitter</a>
          <a href="#">Share on Facebook</a>
        </div>
      </body></html>
    HTML

    result = Parsing::MainContentExtractor.call(html:, url: "https://example.com/test")
    refute_includes result.body_text, "Share on"
  end

  test "removes complementary role elements" do
    html = <<~HTML
      <html><body>
        <article>
          <p>New legislation aims to improve healthcare access for rural communities across the state.</p>
          <p>The bill passed with bipartisan support after months of negotiations.</p>
        </article>
        <div role="complementary">
          <p>Ad: Buy our products now!</p>
        </div>
      </body></html>
    HTML

    result = Parsing::MainContentExtractor.call(html:, url: "https://example.com/test")
    refute_includes result.body_text, "Buy our products"
  end

  test "removes ad container" do
    html = <<~HTML
      <html><body>
        <article>
          <p>Financial markets showed strong performance this quarter with major indices hitting record highs.</p>
        </article>
        <div class="ad-container">
          <p>Sponsored: Investment opportunity!</p>
        </div>
      </body></html>
    HTML

    result = Parsing::MainContentExtractor.call(html:, url: "https://example.com/test")
    refute_includes result.body_text, "Sponsored"
  end
end
