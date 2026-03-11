class HtmlSnapshot < ApplicationRecord
  belongs_to :article

  validates :compressed_html, :content_fingerprint, :original_size, :fetch_url, :captured_at, presence: true
  validates :content_fingerprint, uniqueness: true

  def html
    Zlib::Inflate.inflate(compressed_html)
  end

  def self.store!(article:, html:, url:)
    fingerprint = Digest::SHA256.hexdigest(html)

    find_or_create_by!(content_fingerprint: fingerprint) do |snapshot|
      snapshot.article = article
      snapshot.compressed_html = Zlib::Deflate.deflate(html)
      snapshot.original_size = html.bytesize
      snapshot.fetch_url = url
      snapshot.captured_at = Time.current
    end
  rescue ActiveRecord::RecordNotUnique
    find_by!(content_fingerprint: fingerprint)
  end
end
