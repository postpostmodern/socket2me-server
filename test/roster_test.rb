# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "roster"

class RosterTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/users.yml", __dir__)

  def test_reads_names
    assert_equal %w[k7x2pq9wz3ma m4q9zt2rv8nb], Socket2Me::Roster.names(FIXTURE)
  end

  def test_builds_hosts_from_domain
    assert_equal %w[k7x2pq9wz3ma.socket2me.dev m4q9zt2rv8nb.socket2me.dev],
      Socket2Me::Roster.hosts("socket2me.dev", FIXTURE)
  end

  def test_rejects_non_opaque_names
    with_roster(%w[jason]) do |path|
      err = assert_raises(ArgumentError) { Socket2Me::Roster.names(path) }
      assert_match(/invalid username "jason"/, err.message)
    end
  end

  def test_rejects_uppercase_and_punctuation
    %w[K7x2pq9wz3ma k7x2-pq9wz3ma k7x2.pq9wz3ma].each do |bad|
      with_roster([bad]) do |path|
        assert_raises(ArgumentError, bad) { Socket2Me::Roster.names(path) }
      end
    end
  end

  def test_rejects_duplicates
    with_roster(%w[k7x2pq9wz3ma k7x2pq9wz3ma]) do |path|
      err = assert_raises(ArgumentError) { Socket2Me::Roster.names(path) }
      assert_match(/duplicate/, err.message)
    end
  end

  def test_empty_roster_is_empty_not_an_error
    with_roster([]) do |path|
      assert_equal [], Socket2Me::Roster.names(path)
    end
  end

  private

  def with_roster(names)
    Tempfile.create(["users", ".yml"]) do |f|
      f.write({ "users" => names }.to_yaml)
      f.flush
      yield f.path
    end
  end
end
