require "json"
require "thread"

module SqliteVec
  extend self

  VECTOR_TABLE = "investigation_embedding_vectors".freeze
  LOAD_MARKER = :@frank_investigator_sqlite_vec_loaded

  def enabled?
    Rails.configuration.x.frank_investigator.vector_search_enabled
  end

  def available?
    enabled? && sqlite_connection?(ApplicationRecord.connection) && extension_path.exist?
  rescue StandardError
    false
  end

  def ready?
    return false unless available?

    ensure_ready!
  rescue StandardError => e
    Rails.logger.warn("[SqliteVec] Vector search unavailable: #{e.class}: #{e.message}")
    false
  end

  def insert!(investigation_id:, vector:, connection: ApplicationRecord.connection)
    ensure_ready!(connection:)

    connection.execute("DELETE FROM #{VECTOR_TABLE} WHERE investigation_id = #{connection.quote(investigation_id)}")
    connection.execute(
      <<~SQL.squish
        INSERT INTO #{VECTOR_TABLE} (investigation_id, embedding)
        VALUES (#{connection.quote(investigation_id)}, #{connection.quote(JSON.generate(vector))})
      SQL
    )
  end

  def nearest_neighbors(vector:, limit:, exclude_ids: [], connection: ApplicationRecord.connection)
    ensure_ready!(connection:)

    rows = connection.exec_query(
      <<~SQL.squish
        SELECT investigation_id, distance
        FROM #{VECTOR_TABLE}
        WHERE embedding MATCH #{connection.quote(JSON.generate(vector))}
        ORDER BY distance
        LIMIT #{Integer(limit)}
      SQL
    ).to_a

    rows.reject { |row| exclude_ids.include?(row["investigation_id"]) }
  end

  def extension_path
    Pathname.new(Rails.configuration.x.frank_investigator.sqlite_vec_path)
  end

  def ensure_ready!(connection: ApplicationRecord.connection)
    return false unless enabled?
    raise "sqlite-vec requires SQLite" unless sqlite_connection?(connection)
    raise "sqlite-vec extension missing at #{extension_path}" unless extension_path.exist?

    mutex.synchronize do
      load_extension!(connection)
      ensure_vector_table!(connection)
    end

    true
  end

  private

  def load_extension!(connection)
    raw_connection = connection.raw_connection
    return if raw_connection.instance_variable_get(LOAD_MARKER)

    raw_connection.enable_load_extension(true)
    raw_connection.load_extension(extension_path.to_s)
    raw_connection.enable_load_extension(false)
    raw_connection.instance_variable_set(LOAD_MARKER, true)
  rescue StandardError
    raw_connection.enable_load_extension(false)
    raise
  end

  def ensure_vector_table!(connection)
    dimensions = Rails.configuration.x.frank_investigator.embedding_dimensions
    connection.execute(
      <<~SQL
        CREATE VIRTUAL TABLE IF NOT EXISTS #{VECTOR_TABLE}
        USING vec0(
          investigation_id integer primary key,
          embedding float[#{dimensions}] distance_metric=cosine
        )
      SQL
    )
  end

  def sqlite_connection?(connection)
    connection.adapter_name.casecmp("SQLite").zero?
  end

  def mutex
    @mutex ||= Mutex.new
  end
end
