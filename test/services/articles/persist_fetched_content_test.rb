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
            <meta property="article:published_time" content="2026-03-10T10:30:00-03:00">
          </head>
          <body>
            <article>
              <p>Lei 123 reduz imposto e altera regras fiscais.</p>
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
end
