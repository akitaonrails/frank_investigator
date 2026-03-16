require "test_helper"

class Articles::PersistFetchedContentTest < ActiveSupport::TestCase
  test "stores connector metadata and source classification when persisting fetched content" do
    article = Article.create!(
      url: "https://www.gov.br/fazenda/pt-br/assuntos/exemplo",
      normalized_url: "https://www.gov.br/fazenda/pt-br/assuntos/exemplo",
      host: "www.gov.br"
    )

    Articles::PersistFetchedContent.call(
      article:,
      html: <<~HTML,
        <html>
          <head>
            <title>Lei 123 reduz imposto</title>
            <meta property="og:site_name" content="Gov.br">
            <meta property="og:type" content="article">
            <meta property="article:published_time" content="2026-03-10T10:30:00-03:00">
            <script type="application/ld+json">
              {"@type": "NewsArticle", "headline": "Lei 123 reduz imposto", "datePublished": "2026-03-10T10:30:00-03:00"}
            </script>
          </head>
          <body>
            <article>
              <h1>Lei 123 reduz imposto</h1>
              <p>Lei 123 reduz imposto e altera regras fiscais para empresas de todos os portes no território nacional brasileiro afetando milhões de contribuintes.</p>
              <p>A medida foi aprovada pelo Congresso Nacional e entrará em vigor a partir do próximo semestre fiscal conforme publicação no Diário Oficial da União desta segunda-feira.</p>
              <p>Especialistas estimam que a mudança beneficiará mais de dez milhões de contribuintes em todas as regiões do país incluindo micro e pequenas empresas do setor de serviços.</p>
              <p><a href="https://www12.senado.leg.br/noticias/exemplo">Fonte legislativa</a></p>
            </article>
          </body>
        </html>
      HTML
      fetched_title: "Lei 123 reduz imposto",
      current_depth: 0
    )

    article.reload

    assert_equal "government_record", article.source_kind
    assert_equal "primary", article.authority_tier
    assert article.published_at.present?
    assert_equal "government_record", article.metadata_json["connector"]
    assert_equal "gov.br", article.independence_group
    assert_equal 1, article.sourced_links.count
    assert_equal "legislative_record", article.sourced_links.first.target_article.source_kind
  end

  test "rejects non-article HTML with not_article rejection reason" do
    article = Article.create!(
      url: "https://example.com/denounce",
      normalized_url: "https://example.com/denounce",
      host: "example.com"
    )

    Articles::PersistFetchedContent.call(
      article:,
      html: <<~HTML,
        <html>
          <head><title>Report Comment</title></head>
          <body>
            <h2>Report this comment</h2>
            <form action="/denounce" method="post">
              <label>Reason:</label>
              <select><option>Spam</option><option>Offensive</option></select>
              <button type="submit">Submit</button>
            </form>
          </body>
        </html>
      HTML
      fetched_title: "Report Comment",
      current_depth: 0
    )

    article.reload
    assert_equal "rejected", article.fetch_status
    assert_equal "not_article", article.rejection_reason
  end
end
