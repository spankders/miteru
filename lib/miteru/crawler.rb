# frozen_string_literal: true

require "csv"
require "http"
require "json"
require "thread/pool"
require "uri"

module Miteru
  class Crawler
    attr_reader :directory_traveling
    attr_reader :size
    attr_reader :threads
    attr_reader :verbose

    URLSCAN_ENDPOINT = "https://urlscan.io/api/v1"
    OPENPHISH_ENDPOINT = "https://openphish.com"
    PHISHTANK_ENDPOINT = "http://data.phishtank.com"

    def initialize(directory_traveling: false, size: 100, threads: 10, verbose: false)
      @directory_traveling = directory_traveling
      @size = size
      @threads = threads
      @verbose = verbose
      raise ArgumentError, "size must be less than 100,000" if size > 100_000
    end

    def urlscan_feed
      url = "#{URLSCAN_ENDPOINT}/search/?q=certstream-suspicious&size=#{size}"
      res = JSON.parse(get(url))
      res["results"].map { |result| result.dig("task", "url") }
    rescue HTTPResponseError => _
      []
    end

    def openphish_feed
      res = get("#{OPENPHISH_ENDPOINT}/feed.txt")
      res.lines.map(&:chomp)
    rescue HTTPResponseError => _
      []
    end

    def phishtank_feed
      res = get("#{PHISHTANK_ENDPOINT}/data/online-valid.csv")
      table = CSV.parse(res, headers: true)
      table.map { |row| row["url"] }
    rescue HTTPResponseError => _
      []
    end

    def breakdown(url)
      begin
        uri = URI.parse(url)
      rescue URI::InvalidURIError => _
        return []
      end
      base = "#{uri.scheme}://#{uri.hostname}"
      return [base] unless directory_traveling

      segments = uri.path.split("/")
      return [base] if segments.length.zero?

      urls = (0...segments.length).map { |idx| "#{base}#{segments[0..idx].join('/')}" }
      urls.reject do |breakdowned_url|
        # Reject a url which ends with specific extension names
        %w(.htm .html .php .asp .aspx).any? { |ext| breakdowned_url.end_with? ext }
      end
    end

    def suspicious_urls
      @suspicious_urls ||= [].tap do |arr|
        urls = (urlscan_feed + openphish_feed + phishtank_feed)
        urls.map { |url| breakdown(url) }.flatten.uniq.sort.each { |url| arr << url }
      end
    end

    def execute
      puts "Loaded #{suspicious_urls.length} URLs to crawl." if verbose

      pool = Thread.pool(threads)
      websites = []

      suspicious_urls.each do |url|
        pool.process do
          website = Website.new(url)
          if website.has_kit?
            websites << website
          else
            puts "#{website.url}: it doesn't contain a phishing kit." if verbose
            website.unbuild
          end
        end
      end
      pool.shutdown

      websites
    end

    def self.execute(directory_traveling: false, size: 100, threads: 10, verbose: false)
      new(directory_traveling: directory_traveling, size: size, threads: threads, verbose: verbose).execute
    end

    private

    def get(url)
      res = HTTP.follow(max_hops: 3).get(url)
      raise HTTPResponseError if res.code != 200

      res.body.to_s
    end
  end
end
