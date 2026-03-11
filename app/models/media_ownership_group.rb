class MediaOwnershipGroup < ApplicationRecord
  validates :name, presence: true, uniqueness: true

  def owns_host?(host)
    owned_hosts.any? { |pattern| host.to_s.downcase.include?(pattern.downcase) }
  end

  def owns_independence_group?(group)
    owned_independence_groups.any? { |owned| group.to_s.downcase == owned.downcase }
  end

  def self.group_for_host(host)
    all.find { |group| group.owns_host?(host) }
  end

  def self.same_owner?(host_a, host_b)
    group_a = group_for_host(host_a)
    group_b = group_for_host(host_b)
    group_a.present? && group_a == group_b
  end
end
