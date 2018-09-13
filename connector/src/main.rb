require 'active_support'
require 'active_support/time'
require 'active_support/core_ext/object/blank'

require 'json'

require 'thread'
require 'parallel'

# Debug
require_relative './debug.rb'
require 'yaml'
require 'pry'

require_relative './config.rb'
require_relative './analytics.rb'
require_relative './suggestions_index.rb'
require_relative './source_index.rb'
require_relative './search_string.rb'

def each_index &_block
  raise ArgumentError, 'Missing block' unless block_given?
  CONFIG['indices'].each do |idx|
    idx = SourceIndex.new(idx['name'])
    yield idx, true
    idx.replicas.each do |r|
      yield r, false
    end
  end
end

def target_index
  @target_index ||= SuggestionsIndex.new
end

def transform_facets_exact_count idx, rep
  values = rep['facets'] || {}
  idx.config.facets.map do |facet|
    attr = facet['attribute']
    res = values[attr] || []
    [
      attr,
      res.map { |k, v| { value: k, count: v } }
         .sort_by { |obj| -obj[:count] }
         .first(facet['amount'])
    ]
  end.to_h
end

def transform_facets_analytics idx, rep
  values = rep['topRefinements'] || {}
  idx.config.facets.map do |facet|
    attr = facet['attribute']
    res = values[attr] || []
    [
      attr,
      res.first(facet['amount'])
    ]
  end.to_h
end

def add_to_target_index idx, type, suggestions, primary_index = false
  iter = suggestions.clone.each_with_index
  mutex = Mutex.new
  Parallel.each(iter, in_threads: CONFIG['parallel']) do |(p, i)|
    debug = Debug.new

    q = p['query'].to_s
    pop = p['count'].to_i
    debug.add 'Initial', "#{type} \"#{q}\" - #{pop}", index: idx

    q = SearchString.clean(q)
    debug.add 'Clean', "\"#{q}\"", index: idx

    puts "[#{idx.name}]#{type} Query#{" #{i + 1} / #{iter.size}" if iter.size > 1}: \"#{q}\""

    q = idx.unprefixer.transform q
    debug.add 'Unprefixed', "\"#{q}\"", index: idx
    if q.blank?
      debug.add 'Skipped', "Skipped because unprefixer didn't work", index: idx
      next
    end

    rep = idx.search_exact q
    debug.add 'nbExactHits', rep['nbHits'], index: idx
    if rep['nbHits'] < idx.config.min_hits
      debug.add 'Skip', "Skipped because min_hits = #{idx.config.min_hits}", index: idx
      next
    end

    object = {
      objectID: q,
      query: q,
      nb_words: q.split(' ').size,
      popularity: {
        value: pop,
        _operation: 'Increment'
      }
    }

    if primary_index
      idx_information = {
        idx.name.to_sym => {
          exact_nb_hits: rep['nbHits'],
          facets: {
            exact_matches: transform_facets_exact_count(idx, rep),
            analytics: transform_facets_analytics(idx, p)
          }
        }
      }
      object.merge!(idx_information)
      debug.add 'Facets', 'Values', index: idx, extra: idx_information
    end

    object[:_debug] = { _operation: 'Add', value: debug.entries } if CONFIG['debug']

    mutex.synchronize do
      target_index.add object
      suggestions.delete_at i
    end
  end
end

def main
  each_index do |idx, primary_index|
    popular = Analytics.popular_searches(
      idx.name,
      size: 10_000,
      startAt: (Time.now - idx.config.analytics_days.days).to_i,
      endAt: Time.now.to_i,
      tags: idx.config.analytics_tags.join(','),
      distinctIPCount: idx.config.distinct_by_ip
    )
    add_to_target_index idx, '[Popular]', popular, primary_index

    next unless primary_index

    add_to_target_index idx, '[Generated]', idx.generated, primary_index

    idx.external do |external|
      external.browse do |hit|
        add_to_target_index idx, "[External][#{external.index_name}]", [hit], primary_index
      end
    end
  end

  target_index.push
  target_index.ignore_plurals
  target_index.move_tmp
end
