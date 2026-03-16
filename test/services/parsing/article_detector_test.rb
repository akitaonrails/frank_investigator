require "test_helper"

class Parsing::ArticleDetectorTest < ActiveSupport::TestCase
  test "detects real article with JSON-LD and paragraphs" do
    html = <<~HTML
      <html>
        <head>
          <meta property="og:type" content="article">
          <meta property="article:published_time" content="2026-03-10T10:30:00-03:00">
          <meta name="author" content="João Silva">
          <script type="application/ld+json">
            {"@type": "NewsArticle", "headline": "PIB cresce 2%", "datePublished": "2026-03-10", "author": {"@type": "Person", "name": "João Silva"}}
          </script>
        </head>
        <body>
          <article>
            <h1>PIB cresce 2% no primeiro trimestre de 2026</h1>
            <p>O Produto Interno Bruto brasileiro cresceu dois por cento no primeiro trimestre de 2026, segundo dados divulgados pelo Instituto Brasileiro de Geografia e Estatística nesta segunda-feira em Brasília capital federal do país.</p>
            <p>O resultado ficou acima das expectativas do mercado financeiro que esperava um crescimento de apenas um e meio por cento conforme pesquisa realizada com as principais instituições financeiras do país nos últimos trinta dias.</p>
            <p>Especialistas atribuem o desempenho positivo à retomada do setor de serviços que teve crescimento de três por cento e ao bom momento do agronegócio que registrou alta de quatro por cento no período analisado pelo instituto.</p>
            <p>Para o segundo trimestre as projeções indicam que o ritmo de crescimento deve ser mantido com possibilidade de aceleração caso as exportações continuem em trajetória ascendente como indicam os dados preliminares divulgados.</p>
          </article>
        </body>
      </html>
    HTML

    result = Parsing::ArticleDetector.call(html: html)

    assert result.article, "Expected article to be detected, score: #{result.score}"
    assert result.score >= 0.30
    assert result.signals[:jsonld_article_type]
    assert result.signals[:og_type_article]
    assert result.signals[:published_timestamp]
    assert result.signals[:author_metadata]
  end

  test "detects old-school article without JSON-LD but with paragraphs, H1, and article tag" do
    html = <<~HTML
      <html>
        <head><title>Reforma tributária avança</title></head>
        <body>
          <article>
            <h1>Reforma tributária avança no Congresso Nacional</h1>
            <p>A reforma tributária deu mais um passo importante nesta terça-feira com a aprovação do texto-base na Comissão Especial da Câmara dos Deputados que analisava a proposta desde o início do ano legislativo corrente no Brasil onde os parlamentares têm trabalhado intensamente para aprovar as mudanças necessárias na legislação fiscal do país inteiro.</p>
            <p>O relator da proposta apresentou modificações significativas no texto original que incluem novas alíquotas para os setores de tecnologia e serviços digitais que antes não estavam contemplados na versão inicial do projeto de lei complementar que tramita desde o segundo semestre do ano passado nas comissões especializadas da casa legislativa federal brasileira.</p>
            <p>Parlamentares da oposição criticaram a velocidade da tramitação e pediram mais tempo para analisar os impactos da medida sobre os municípios de pequeno porte que dependem fortemente das receitas de impostos sobre serviços locais prestados por empresas de diversos segmentos econômicos em todas as regiões do território nacional brasileiro incluindo o norte e nordeste.</p>
            <p>Os representantes dos estados do sul e sudeste apoiaram a medida argumentando que ela trará simplificação ao sistema tributário atual que é considerado um dos mais complexos do mundo inteiro conforme análise de especialistas internacionais em reforma fiscal e administração tributária comparada entre nações desenvolvidas.</p>
          </article>
        </body>
      </html>
    HTML

    result = Parsing::ArticleDetector.call(html: html)

    assert result.article, "Expected old-school article to be detected, score: #{result.score}"
    assert result.signals[:semantic_article_tag]
    assert result.signals[:h1_present]
  end

  test "rejects listing/category page with high link density and no metadata" do
    links = (1..30).map { |i| %(<li><a href="/article/#{i}">Article title number #{i}</a></li>) }.join("\n")
    html = <<~HTML
      <html>
        <head><title>Economia - Portal de Notícias</title></head>
        <body>
          <h1>Economia</h1>
          <nav><a href="/">Home</a> <a href="/politica">Política</a> <a href="/economia">Economia</a></nav>
          <ul>#{links}</ul>
          <a href="/page/2">Próxima página</a>
        </body>
      </html>
    HTML

    result = Parsing::ArticleDetector.call(html: html)

    assert_not result.article, "Expected listing page to be rejected, score: #{result.score}"
    assert_not result.signals[:jsonld_article_type]
    assert_not result.signals[:og_type_article]
  end

  test "rejects homepage with navigation-heavy content" do
    sections = (1..10).map { |i| %(<div><a href="/section/#{i}">Section #{i}</a> <a href="/topic/#{i}">Topic #{i}</a></div>) }.join("\n")
    html = <<~HTML
      <html>
        <head><title>Portal de Notícias</title></head>
        <body>
          <nav><a href="/">Home</a> <a href="/about">Sobre</a> <a href="/contact">Contato</a></nav>
          #{sections}
          <footer><a href="/privacy">Privacy</a> <a href="/terms">Terms</a></footer>
        </body>
      </html>
    HTML

    result = Parsing::ArticleDetector.call(html: html)

    assert_not result.article, "Expected homepage to be rejected, score: #{result.score}"
  end

  test "rejects comment/denounce page with short content and no structure" do
    html = <<~HTML
      <html>
        <head><title>Denunciar Comentário</title></head>
        <body>
          <h2>Denunciar este comentário</h2>
          <form action="/denounce" method="post">
            <label>Motivo:</label>
            <select><option>Spam</option><option>Ofensivo</option></select>
            <textarea></textarea>
            <button type="submit">Enviar</button>
          </form>
        </body>
      </html>
    HTML

    result = Parsing::ArticleDetector.call(html: html)

    assert_not result.article, "Expected denounce page to be rejected, score: #{result.score}"
  end

  test "detects article with JSON-LD @graph structure" do
    html = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">
            {"@graph": [{"@type": "WebPage"}, {"@type": "NewsArticle", "headline": "Test", "datePublished": "2026-03-10"}]}
          </script>
        </head>
        <body>
          <h1>Test Article</h1>
          <p>Content paragraph one.</p>
        </body>
      </html>
    HTML

    result = Parsing::ArticleDetector.call(html: html)

    assert result.signals[:jsonld_article_type]
    assert result.signals[:published_timestamp]
  end

  test "handles malformed JSON-LD gracefully" do
    html = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">{ broken json }</script>
        </head>
        <body><p>Some text</p></body>
      </html>
    HTML

    result = Parsing::ArticleDetector.call(html: html)

    assert_not result.signals[:jsonld_article_type]
  end

  test "score calculation matches expected weights" do
    html = <<~HTML
      <html>
        <head>
          <script type="application/ld+json">
            {"@type": "NewsArticle", "datePublished": "2026-01-01", "author": {"name": "Test"}}
          </script>
        </head>
        <body><p>Short</p></body>
      </html>
    HTML

    result = Parsing::ArticleDetector.call(html: html)

    assert_equal 0.45, result.score
    assert result.article
  end
end
