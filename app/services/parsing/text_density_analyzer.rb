module Parsing
  class TextDensityAnalyzer
    # Density-based content extraction fallback.
    # Walks block elements, computes text_length / (child_tag_count + 1),
    # clusters adjacent high-density nodes, and returns the best cluster's text.
    BLOCK_TAGS = %w[p div section blockquote li h1 h2 h3 h4 h5 h6 td pre].to_set.freeze
    MIN_DENSITY = 40

    def self.extract(document)
      new(document).extract
    end

    def initialize(document)
      @document = document
    end

    def extract
      body = @document.at_css("body")
      return nil unless body

      scored = body.css(BLOCK_TAGS.to_a.join(", ")).filter_map do |node|
        text = node.text.to_s.squish
        next if text.length < 20

        child_tags = node.element_children.count
        density = text.length.to_f / (child_tags + 1)
        next if density < MIN_DENSITY

        { node: node, text: text, density: density }
      end

      return nil if scored.empty?

      # Cluster adjacent high-density nodes
      best_cluster = cluster_adjacent(scored)
      return nil if best_cluster.empty?

      best_cluster.map { |entry| entry[:text] }.join("\n\n")
    end

    private

    def cluster_adjacent(scored)
      clusters = []
      current_cluster = [scored.first]

      scored.each_cons(2) do |prev, curr|
        # Check if nodes are siblings or close in document order
        if siblings_or_close?(prev[:node], curr[:node])
          current_cluster << curr
        else
          clusters << current_cluster
          current_cluster = [curr]
        end
      end
      clusters << current_cluster

      clusters.max_by { |c| c.sum { |entry| entry[:text].length } } || []
    end

    def siblings_or_close?(a, b)
      a.parent == b.parent || a.parent == b || b.parent == a
    end
  end
end
