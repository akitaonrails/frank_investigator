require "test_helper"

class Investigations::EmbeddingIndexerTest < ActiveSupport::TestCase
  test "indexes embeddings into sqlite-vec and metadata table" do
    article = Article.create!(
      url: "https://example.com/indexer",
      normalized_url: "https://example.com/indexer",
      host: "example.com",
      title: "Rombo fiscal aumenta",
      body_text: "O texto discute Haddad, rombo fiscal e impostos.",
      fetch_status: :fetched
    )
    investigation = Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :completed
    )

    embedding_response = Struct.new(:vectors).new(Array.new(1536, 0.25))

    with_singleton_stub(SqliteVec, :ready?, true) do
      with_singleton_stub(SqliteVec, :insert!, true) do
        with_singleton_stub(RubyLLM, :embed, embedding_response) do
          record = Investigations::EmbeddingIndexer.call(investigation:)

          assert_predicate record, :indexed?
          assert_equal 1536, record.dimensions
          assert_equal "openai/text-embedding-3-small", record.model_id
          assert_equal 1536, JSON.parse(record.embedding_json).size
          assert_nil record.error_class
        end
      end
    end
  end

  test "records failures without raising" do
    article = Article.create!(
      url: "https://example.com/indexer-fail",
      normalized_url: "https://example.com/indexer-fail",
      host: "example.com",
      title: "Rombo fiscal aumenta",
      body_text: "O texto discute Haddad, rombo fiscal e impostos.",
      fetch_status: :fetched
    )
    investigation = Investigation.create!(
      submitted_url: article.url,
      normalized_url: article.normalized_url,
      root_article: article,
      status: :completed
    )

    with_singleton_stub(SqliteVec, :ready?, true) do
      with_singleton_stub(RubyLLM, :embed, ->(*) { raise StandardError, "provider down" }) do
        record = Investigations::EmbeddingIndexer.call(investigation:)

        assert_nil record
        persisted = investigation.reload.investigation_embedding
        assert_predicate persisted, :failed?
        assert_equal "StandardError", persisted.error_class
        assert_match "provider down", persisted.error_message
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
end
