class PagesController < ApplicationController
  def terms
    expires_in 1.day, public: true
  end

  def methodology
    expires_in 1.day, public: true
  end
end
