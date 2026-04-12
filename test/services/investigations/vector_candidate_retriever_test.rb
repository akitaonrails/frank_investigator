require "test_helper"

class Investigations::VectorCandidateRetrieverTest < ActiveSupport::TestCase
  test "returns indexed neighbor investigations in similarity order" do
    root_article = Article.create!(
      url: "https://example.com/source",
      normalized_url: "https://example.com/source",
      host: "example.com",
      title: "Haddad foi um bom ministro",
      body_text: "Texto sobre Haddad, impostos e fiscal.",
      fetch_status: :fetched
    )
    source = Investigation.create!(
      submitted_url: root_article.url,
      normalized_url: root_article.normalized_url,
      root_article: root_article,
      status: :completed
    )
    source.create_investigation_embedding!(
      status: :indexed,
      model_id: "openai/text-embedding-3-small",
      dimensions: 1536,
      content_digest: "source-digest",
      embedding_json: JSON.generate(Array.new(1536, 0.1)),
      indexed_at: Time.current
    )

    candidate_a = create_candidate("https://example.com/a", "Após aumentos de impostos, Haddad deixa a Fazenda")
    candidate_b = create_candidate("https://example.com/b", "Rombo fiscal explode no governo")
    create_candidate("https://example.com/c", "Artigo sem embedding util")

    InvestigationEmbedding.where(investigation_id: candidate_a.id).update_all(status: "indexed")
    InvestigationEmbedding.where(investigation_id: candidate_b.id).update_all(status: "indexed")

    with_singleton_stub(SqliteVec, :ready?, true) do
      with_singleton_stub(SqliteVec, :nearest_neighbors, [
        { "investigation_id" => source.id, "distance" => 0.0 },
        { "investigation_id" => candidate_b.id, "distance" => 0.1 },
        { "investigation_id" => candidate_a.id, "distance" => 0.2 }
      ]) do
        with_singleton_stub(Investigations::EmbeddingIndexer, :call, source.investigation_embedding) do
          investigations = Investigations::VectorCandidateRetriever.call(investigation: source, limit: 5)

          assert_equal [ candidate_b.id, candidate_a.id ], investigations.map(&:id)
        end
      end
    end
  end

  private

  def with_singleton_stub(receiver, method_name, value)
    original_method = receiver.method(method_name) if receiver.respond_to?(method_name)

    receiver.define_singleton_method(method_name) do |*args|
      value.respond_to?(:call) ? value.call(*args) : value
    end
    yield
  ensure
    if original_method
      receiver.define_singleton_method(method_name, original_method)
    else
      receiver.singleton_class.remove_method(method_name)
    end
  end

  def create_candidate(url, title)
    article = Article.create!(
      url:,
      normalized_url: url,
      host: "example.net",
      title:,
      body_text: "#{title} com mais detalhes sobre impostos e fiscal.",
      fetch_status: :fetched
    )
    investigation = Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :completed
    )
    investigation.create_investigation_embedding!(
      status: :pending,
      model_id: "openai/text-embedding-3-small",
      dimensions: 1536,
      content_digest: SecureRandom.hex(8),
      embedding_json: JSON.generate(Array.new(1536, 0.2)),
      indexed_at: Time.current
    )
    investigation
  end
end
