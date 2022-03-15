# encoding: utf-8
require 'cgi'
require 'net/http'
require 'uri'

require 'json' unless defined?(JSON)

require 'prismic/with_fragments'

module Prismic

  EXPERIMENTS_COOKIE = 'io.prismic.experiment'

  PREVIEW_COOKIE = 'io.prismic.preview'

  # These exception can contains an error cause and is able to show them
  class Error < Exception
    attr_reader :cause
    def initialize(msg=nil, cause=nil)
      msg ? super(msg) : msg
      @cause = cause
    end

    # Return the full trace of the error (including nested errors)
    # @param [Exception] e Parent error (for internal use)
    #
    # @return [String] The trace
    def full_trace(e=self)
      first, *backtrace = e.backtrace
      msg = e == self ? "" : "Caused by "
      msg += "#{first}: #{e.message} (#{e.class})"
      stack = backtrace.map{|s| "\tfrom #{s}" }.join("\n")
      cause = e.respond_to?(:cause) ? e.cause : nil
      cause_stack = cause ? full_trace(cause) : nil
      [msg, stack, cause_stack].compact.join("\n")
    end
  end

  # Return an API instance
  # @api
  #
  # The access token and HTTP client can be provided.
  #
  # The HTTP Client must responds to same method than {DefaultHTTPClient}.
  #
  # @overload api(url)
  #   Simpler syntax (no configuration)
  #   @param [String] url The URL of the prismic.io repository
  # @overload api(url, opts)
  #   Standard use
  #   @param [String] url The URL of the prismic.io repository
  #   @param [Hash] opts The options
  #   @option opts [String] :access_token (nil) The access_token
  #   @option opts :http_client (DefaultHTTPClient) The HTTP client to use
  #   @option opts :api_cache (nil) The caching object for the /api endpoint cache (for instance Prismic::Cache) to use
  #   @option opts :cache (nil) The caching object (for instance Prismic::Cache) to use, or false for no caching
  # @overload api(url, access_token)
  #   Provide the access_token (only)
  #   @param [String] url The URL of the prismic.io repository
  #   @param [String] access_token The access token
  #
  # @raise PrismicWSConnectionError
  #
  # @return [API] The API instance related to this repository
  def self.api(url, opts=nil)
    if (not url =~ /\A#{URI::regexp(['http', 'https'])}\z/)
      raise ArgumentError.new("Valid web URI expected")
    end
    opts ||= {}
    opts = {access_token: opts} if opts.is_a?(String)
    API.start(url, opts)
  end

  # Build the URL where the user can be redirected to authenticated himself
  # using OAuth2.
  # @api
  #
  # @note: The endpoint depends on the repository, so an API call is made to
  # fetch it.
  #
  # @param url[String] The URL of the prismic.io repository
  # @param oauth_opts [Hash] The OAuth2 options
  # @param api_opts [Hash] The API options (the same than accepted by the {api}
  #                        method)
  #
  # @option oauth_opts :client_id [String] The Application's client ID
  # @option oauth_opts :redirect_uri [String] The Application's secret
  # @option oauth_opts :scope [String] The desired scope
  #
  # @raise PrismicWSConnectionError
  #
  # @return [String] The built URL
  def self.oauth_initiate_url(url, oauth_opts, api_opts=nil)
    api_opts ||= {}
    api_opts = {access_token: api_opts} if api_opts.is_a?(String)
    API.oauth_initiate_url(url, oauth_opts, api_opts)
  end

  # Check a token and return an access_token
  #
  # This method allows to check the token received when the user has been
  # redirected from the OAuth2 server. It returns an access_token that can
  # be used to authenticate the user on the API.
  #
  # @param url [String] The URL of the prismic.io repository
  # @param oauth_opts [Hash] The OAuth2 options
  # @param api_opts [Hash] The API options (the same than accepted by the
  #                        {api} method)
  #
  # @option oauth_opts :client_id [String] The Application's client ID
  # @option oauth_opts :redirect_uri [String] The Application's secret
  #
  # @raise PrismicWSConnectionError
  #
  # @return [String] the access_token
  def self.oauth_check_token(url, oauth_opts, api_opts=nil)
    api_opts ||= {}
    api_opts = {access_token: api_opts} if api_opts.is_a?(String)
    API.oauth_check_token(url, oauth_opts, api_opts)
  end

  # A SearchForm represent a Form returned by the prismic.io API.
  #
  # These forms depend on the prismic.io repository, and can be filled and sent
  # as regular HTML forms.
  #
  # You may get a SearchForm instance through the {API#form} method.
  #
  # The SearchForm instance contains helper methods for each predefined form's fields.
  # Note that these methods are not created if they risk to add confusion:
  #
  # - only letters, underscore and digits are authorized in the name
  # - name starting with a digit or an underscore are forbidden
  # - generated method can't override existing methods
  #
  # @example
  #   search_form = api.form('everything')
  #   search_form.page(3)  # specify the field 'page'
  #   search_form.page_size("20")  # specify the 'page_size' field
  #   results = search_form.submit(master_ref)  # submit the search form
  #   results = api.form('everything').page(3).page_size("20").submit(master_ref) # methods can be chained
  class SearchForm
    attr_accessor :api, :form, :data, :ref

    def initialize(api, form, data={}, ref=nil)
      @api = api
      @form = form
      @data = {}
      form.fields.each { |name, _| create_field_helper_method(name) }
      form.default_data.each { |key, value| set(key, value) }
      data.each { |key, value| set(key, value) }
      @ref = ref
    end

    # Specify a query for this form.
    #   @param  query [String] The query
    #   @return [SearchForm] self
    def query(*query)
      q(*query)
    end

    def q(*query)
      def serialize(field)
        if field.kind_of?(String) and not (field.start_with?('my.') or field.start_with?('document'))
          %("#{field}")
        elsif field.kind_of?(Array)
          %([#{field.map{ |arg| serialize(arg) }.join(', ')}])
        else
          %(#{field})
        end
      end
      if query[0].kind_of?(String)
        set('q', query[0])
      else
        unless query[0][0].kind_of?(Array)
          query = [query]
        end
        predicates = query.map { |predicate|
          predicate.map { |q|
            op = q[0]
            rest = q[1..-1]
            "[:d = #{op}(#{rest.map { |arg| serialize(arg) }.join(', ')})]"
          }.join('')
        }
        set('q', "[#{predicates * ''}]")
      end
    end

    # @!method orderings(orderings)
    #   Specify a orderings for this form.
    #   @param  orderings [String] The orderings
    #   @return [SearchForm] self

    # @!method page(page)
    #   Specify a page for this form.
    #   @param  page [String,Fixum] The page
    #   @return [SearchForm] self

    # @!method page_size(page_size)
    #   Specify a page size for this form.
    #   @param  page_size [String,Fixum] The page size
    #   @return [SearchForm] self

    # @!method fetch(fields)
    #   Restrict the document fragments to the specified fields
    #   @param  fields [String] The fields separated by commas (,)
    #   @return [SearchForm] self

    # @!method fetch_links(fields)
    #   Include the document fragments correspondong to the specified fields for DocumentLink
    #   @param  fields [String] The fields separated by commas (,)
    #   @return [SearchForm] self

    # @!method lang(lang)
    #   Specify a language for this form.
    #   @param  lang [String] The document language
    #   @return [SearchForm] self

    # Create the fields'helper methods
    def create_field_helper_method(name)
      return if name == 'ref'
      return unless name =~ /\A[a-zA-Z][a-zA-Z0-9_]*\z/
      meth_name = name.gsub(/([A-Z])/, '_\1').downcase
      return if respond_to?(meth_name)
      define_singleton_method(meth_name){|value| set(name, value) }
    end
    private :create_field_helper_method

    # Returns the form's name
    #
    # @return [String]
    def form_name
      form.name
    end

    # Returns the form's HTTP method
    #
    # @return [String]
    def form_method
      form.form_method
    end

    # Returns the form's relationship
    #
    # @return [String]
    def form_rel
      form.rel
    end

    # Returns the form's encoding type
    #
    # @return [String]
    def form_enctype
      form.enctype
    end

    # Returns the form's action (URL)
    #
    # @return [String]
    def form_action
      form.action
    end

    # Returns the form's fields
    #
    # @return [String]
    def form_fields
      form.fields
    end

    # Submit the form
    # @api
    #
    # @note The reference MUST be defined, either by:
    #
    #       - setting it at {API#create_search_form creation}
    #       - using the {#ref} method
    #       - providing the ref parameter.
    #
    # @param ref [Ref, String] The {Ref reference} to use (if not already
    #     defined)
    #
    # @return [Response] The results (array of Document object + pagination
    #     specifics)
    def submit(ref = nil)
      Prismic::JsonParser.response_parser(JSON.load(submit_raw(ref)))
    end

    # Submit the form, returns a raw JSON string
    # @api
    #
    # @note The reference MUST be defined, either by:
    #
    #       - setting it at {API#create_search_form creation}
    #       - using the {#ref} method
    #       - providing the ref parameter.
    #
    # @param ref [Ref, String] The {Ref reference} to use (if not already
    #     defined)
    #
    # @return [string] The JSON string returned by the API
    def submit_raw(ref = nil)
      self.ref(ref) if ref
      data['ref'] = @ref
      raise NoRefSetException unless @ref

      # cache_key is a mix of HTTP URL and HTTP method
      cache_key = form_method+'::'+form_action+'?'+data.map{|k,v|"#{k}=#{v}"}.join('&')

      from_cache = api.has_cache? && api.cache.get(cache_key)
      if (from_cache)
        from_cache
      else
        if form_method == 'GET' && form_enctype == 'application/x-www-form-urlencoded'
          data['access_token'] = api.access_token if api.access_token
          data.delete_if { |k, v| v.nil? }

          response = api.http_client.get(form_action, data, 'Accept' => 'application/json')

          if response.code.to_s == '200'
            ttl = (response['Cache-Control'] || '').scan(/max-age\s*=\s*(\d+)/).flatten.first
            if ttl != nil && api.has_cache?
              api.cache.set(cache_key, response.body, ttl.to_i)
            end
            response.body
          else
            body = JSON.load(response.body) rescue response.body
            raise AuthenticationException, body if response.code.to_s == '401'
            raise AuthorizationException, body if response.code.to_s == '403'
            raise RefNotFoundException, body if response.code.to_s == '404'
            raise FormSearchException, body
          end
        else
          raise UnsupportedFormKind, "Unsupported kind of form: #{form_method} / #{enctype}"
        end
      end
    end

    # Specify a parameter for this form
    # @param  field_name [String] The parameter's name
    # @param  value [String] The parameter's value
    #
    # @return [SearchForm] self
    def set(field_name, value)
      field = @form.fields[field_name]
      unless value == nil
        if value == ""
          data[field_name] = nil
        elsif field && field.repeatable?
          data[field_name] = [] unless data.include? field_name
          data[field_name] << value.to_s
        else
          data[field_name] = value.to_s
        end
      end
      self
    end

    # Set the {Ref reference} to use
    # @api
    # @param  ref [Ref, String] The {Ref reference} to use
    #
    # @return [SearchForm] self
    def ref(ref)
      @ref = ref.is_a?(Ref) ? ref.ref : ref
      self
    end

    class NoRefSetException < Error ; end
    class UnsupportedFormKind < Error ; end
    class AuthorizationException < Error ; end
    class AuthenticationException < Error ; end
    class RefNotFoundException < Error ; end
    class FormSearchException < Error ; end
  end

  class Field
    attr_accessor :field_type, :default, :repeatable

    def initialize(field_type, default, repeatable = false)
      @field_type = field_type
      @default = default
      @repeatable = repeatable
    end

    alias :repeatable? :repeatable
  end

  # Paginated response to a Prismic.io query. Note that you may not get all documents in the first page,
  # and may need to retrieve more pages or increase the page size.
  class Response
    # @return [Number] current page, starting at 1
    attr_accessor :page
    # @return [Number]
    attr_accessor :results_per_page
    # @return [Number]
    attr_accessor :results_size
    # @return [Number]
    attr_accessor :total_results_size
    # @return [Number]
    attr_accessor :total_pages
    # @return [String] URL to the next page - nil if current page is the last page
    attr_accessor :next_page
    # @return [String] URL to the previous page - nil if current page is the first page
    attr_accessor :prev_page
    # @return [Array<Document>] Documents of the current page
    attr_accessor :results

    # To be able to use Kaminari as a paginator in Rails out of the box
    alias :current_page :page
    alias :limit_value :results_per_page

    def initialize(page, results_per_page, results_size, total_results_size, total_pages, next_page, prev_page, results)
      @page = page
      @results_per_page = results_per_page
      @results_size = results_size
      @total_results_size = total_results_size
      @total_pages = total_pages
      @next_page = next_page
      @prev_page = prev_page
      @results = results
    end

    # Accessing the i-th document in the results
    # @return [Document]
    def [](i)
      @results[i]
    end
    alias :get :[]

    # Iterates over received documents
    #
    # @yieldparam document [Document]
    #
    # This method _does not_ paginates by itself. So only the received document
    # will be returned.
    def each(&blk)
      @results.each(&blk)
    end
    include Enumerable  # adds map, select, etc

    # Return the number of returned documents
    #
    # @return [Fixum]
    def length
      @results.length
    end
    alias :size :length
  end

  class Document
    include Prismic::WithFragments

    # @return [String]
    attr_accessor :id
    # @return [String]
    attr_accessor :uid
    # @return [String]
    attr_accessor :type
    # @return [String]
    attr_accessor :href
    # @return [Array<String>]
    attr_accessor :tags
    # @return [Array<String>]
    attr_accessor :slugs
    # @return Time
    attr_accessor :first_publication_date
    # @return Time
    attr_accessor :last_publication_date
    # @return [String]
    attr_accessor :lang
    # @return [Array<AlternateLanguage>]
    attr_accessor :alternate_languages
    # @return [Array<Fragment>]
    attr_accessor :fragments

    def initialize(
      id,
      uid,
      type,
      href,
      tags,
      slugs,
      first_publication_date,
      last_publication_date,
      lang,
      alternate_languages,
      fragments
    )
      @id = id
      @uid = uid
      @type = type
      @href = href
      @tags = tags
      @slugs = slugs
      @first_publication_date = first_publication_date
      @last_publication_date = last_publication_date
      @lang = lang
      @alternate_languages = alternate_languages
      @fragments = fragments
    end

    # Returns the document's slug
    #
    # @return [String]
    def slug
      slugs.empty? ? '-' : slugs.first
    end

  end


  # Represent a prismic.io reference, a fix point in time.
  #
  # The references must be provided when accessing to any prismic.io resource
  # (except /api) and allow to assert that the URL you use will always
  # returns the same results.
  class Ref

    # Returns the value of attribute id.
    #
    # @return [String]
    attr_accessor :id

    # Returns the value of attribute ref.
    #
    # @return [String]
    attr_accessor :ref

    # Returns the value of attribute label.
    #
    # @return [String]
    attr_accessor :label

    # Returns the value of attribute is_master.
    #
    # @return [Boolean]
    attr_accessor :is_master

    # Returns the value of attribute scheduled_at.
    #
    # @return [Time]
    attr_accessor :scheduled_at

    def initialize(id, ref, label, is_master = false, scheduled_at = nil)
      @id = id
      @ref = ref
      @label = label
      @is_master = is_master
      @scheduled_at = scheduled_at
    end

    alias :master? :is_master
  end

  # The LinkResolver will help to build URL specific to an application, based
  # on a generic prismic.io's {Fragments::DocumentLink Document link}.
  #
  # The {Prismic.link_resolver} function is the recommended way to create a LinkResolver.
  class LinkResolver
    attr_reader :ref

    # @yieldparam doc_link [Fragments::DocumentLink] A DocumentLink instance
    # @yieldreturn [String] The application specific URL of the given document
    def initialize(ref, &blk)
      @ref = ref
      @blk = blk
    end
    def link_to(doc)
      if doc.is_a? Prismic::Fragments::DocumentLink
        @blk.call(doc)
      elsif doc.is_a? Prismic::Document
        doc_link = Prismic::Fragments::DocumentLink.new(doc.id, doc.uid, doc.type, doc.tags, doc.slug, doc.lang, doc.fragments, false)
        @blk.call(doc_link)
      end
    end
  end

  # A class to override the default was to serialize HTML. Only needed if you want to override the default HTML serialization.
  #
  # The {Prismic.html_serializer} function is the recommended way to create an HtmlSerializer.
  class HtmlSerializer
    def initialize(&blk)
      @blk = blk
    end

    def serialize(element, content)
      @blk.call(element, content)
    end
  end
  

  # A class for the alternate language versions of a document 
  #
  # The {Prismic.alternate_language} function is the recommended way to create an AlternateLanguage.
  class AlternateLanguage
    # @return [String]
    attr_accessor :id
    # @return [String]
    attr_accessor :uid
    # @return [String]
    attr_accessor :type
    # @return [String]
    attr_accessor :lang

    def initialize(json)
      @id = json['id']
      @uid = json['uid']
      @type = json['type']
      @lang = json['lang']
    end
  end

  # Default HTTP client implementation, using the standard Net::HTTP library.
  module DefaultHTTPClient
    class << self
      # Performs a GET call and returns the result
      #
      # The result must respond to
      # - code: returns the response's HTTP status code (as number or String)
      # - body: returns the response's body (as String)
      def get(uri, data={}, headers={})
        uri = URI(uri) if uri.is_a?(String)
        add_query(uri, data)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme =~ /https/i
        http.get(uri.request_uri, headers)
      end

      # Performs a POST call and returns the result
      #
      # The result must respond to
      # - code: returns the response's HTTP status code (as number or String)
      # - body: returns the response's body (as String)
      def post(uri, data={}, headers={})
        uri = URI(uri) if uri.is_a?(String)
        add_query(uri, data)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme =~ /https/i
        http.post(uri.path, uri.query, headers)
      end

      def url_encode(data)
        # Can't use URI.encode_www_form (doesn't support multi-values in 1.9.2)
        encode = ->(k, v){ "#{k}=#{CGI::escape(v)}" }
        data.map { |k, vs|
          if vs.is_a?(Array)
            vs.map{|v| encode.(k, v) }.join("&")
          else
            encode.(k, vs)
          end
        }.join("&")
      end

      private

      def add_query(uri, query)
        query = url_encode(query)
        query = "#{uri.query}&#{query}"if uri.query && !uri.query.empty?
        uri.query = query
      end
    end
  end

  # Build a {LinkResolver} instance
  # @api
  #
  # The {LinkResolver} will help to build URL specific to an application, based
  # on a generic prismic.io's {Fragments::DocumentLink Document link}.
  #
  # @param ref [Ref] The ref to use
  # @yieldparam doc_link [Fragments::DocumentLink] A DocumentLink instance
  # @yieldreturn [String] The application specific URL of the given document
  #
  # @return [LinkResolver] the {LinkResolver} instance
  def self.link_resolver(ref, &blk)
    LinkResolver.new(ref, &blk)
  end

  def self.html_serializer(&blk)
    HtmlSerializer.new(&blk)
  end

end

require 'prismic/api'
require 'prismic/form'
require 'prismic/fragments'
require 'prismic/predicates'
require 'prismic/experiments'
require 'prismic/json_parsers'
require 'prismic/cache/lru'
