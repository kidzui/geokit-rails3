require 'active_record'
require 'active_support/concern'

module Geokit
  module ActsAsMappable
    
    class UnsupportedAdapter < StandardError ; end

    # Add the +acts_as_mappable+ method into ActiveRecord subclasses
    module Glue # :nodoc:
      extend ActiveSupport::Concern
      
      module ClassMethods # :nodoc:
        def acts_as_mappable(options = {})
          metaclass = (class << self; self; end)

          include Geokit::ActsAsMappable

          cattr_accessor :through
          self.through = options[:through]

          if reflection = Geokit::ActsAsMappable.end_of_reflection_chain(self.through, self)
            metaclass.instance_eval do
              [ :distance_column_name, :default_units, :default_formula, :lat_column_name, :lng_column_name, :qualified_lat_column_name, :qualified_lng_column_name ].each do |method_name|
                define_method method_name do
                  reflection.klass.send(method_name)
                end
              end
            end
          else
            cattr_accessor :distance_column_name, :default_units, :default_formula, :lat_column_name, :lng_column_name, :qualified_lat_column_name, :qualified_lng_column_name

            self.distance_column_name = options[:distance_column_name]  || 'distance'
            self.default_units = options[:default_units] || Geokit::default_units
            self.default_formula = options[:default_formula] || Geokit::default_formula
            self.lat_column_name = options[:lat_column_name] || 'lat'
            self.lng_column_name = options[:lng_column_name] || 'lng'
            self.qualified_lat_column_name = "#{table_name}.#{lat_column_name}"
            self.qualified_lng_column_name = "#{table_name}.#{lng_column_name}"

            if options.include?(:auto_geocode) && options[:auto_geocode]
              # if the form auto_geocode=>true is used, let the defaults take over by suppling an empty hash
              options[:auto_geocode] = {} if options[:auto_geocode] == true
              cattr_accessor :auto_geocode_field, :auto_geocode_error_message
              self.auto_geocode_field = options[:auto_geocode][:field] || 'address'
              self.auto_geocode_error_message = options[:auto_geocode][:error_message] || 'could not locate address'

              # set the actual callback here
              before_validation :auto_geocode_address, :on => :create
            end
          end
        end
      end
    end # Glue
    
    class Relation < ActiveRecord::Relation
      attr_accessor :distance_formula
      
      def where(opts, *rest)
        relation = clone
        unless opts.blank?
          where_values = build_where(opts, rest)
          relation.where_values += substitute_distance_in_values(where_values)
        end
        relation
      end
      
      def order(*args)
        relation = clone
        unless args.blank?
          order_values = args.flatten
          relation.order_values += substitute_distance_in_values(order_values)
        end
        relation
      end
      
    private
      def substitute_distance_in_values(values)
        return values unless @distance_formula
        # substitute distance with the actual distance equation
        pattern = Regexp.new("\\b#{@klass.distance_column_name}\\b")
        values.map {|value| value.is_a?(String) ? value.gsub(pattern, @distance_formula) : value }
      end
    end
    
    class << self
      def end_of_reflection_chain(through, klass)
        while through
          reflection = nil
          if through.is_a?(Hash)
            association, through = through.to_a.first
          else
            association, through = through, nil
          end

          if reflection = klass.reflect_on_association(association)
            klass = reflection.klass
          else
            raise ArgumentError, "You gave #{association} in :through, but I could not find it on #{klass}."
          end
        end

        reflection
      end
    end
    
    extend ActiveSupport::Concern

    included do
      include Geokit::Mappable
    end
    
    # Instance methods included in models when +acts_as_mappable+ is called
    module InstanceMethods
      # this is the callback for auto_geocoding
      def auto_geocode_address
        address=self.send(auto_geocode_field).to_s
        geo=Geokit::Geocoders::MultiGeocoder.geocode(address)

        if geo.success
          self.send("#{lat_column_name}=", geo.lat)
          self.send("#{lng_column_name}=", geo.lng)
        else
          errors.add(auto_geocode_field, auto_geocode_error_message)
        end

        geo.success
      end
    end

    # Class methods included in models when +acts_as_mappable+ is called
    module ClassMethods
      # A proxy to an instance of a finder adapter, inferred from the connection's adapter.
      def adapter
        @adapter ||= begin
          require File.join(File.dirname(__FILE__), 'adapters', connection.adapter_name.downcase)
          klass = Adapters.const_get(connection.adapter_name.camelcase)
          klass.load(self) unless klass.loaded
          klass.new(self)
        rescue LoadError
          raise UnsupportedAdapter, "`#{connection.adapter_name.downcase}` is not a supported adapter."
        end
      end

      def within(distance, options = {})
        options[:within] = distance
        geo_scope(options)
      end
      alias inside within

      def beyond(distance, options = {})
        options[:beyond] = distance
        geo_scope(options)
      end
      alias outside beyond

      def in_range(range, options = {})
        options[:range] = range
        geo_scope(options)
      end

      def in_bounds(bounds, options = {})
        options[:bounds] = bounds
        geo_scope(options)
      end

      def closest(options = {})
        geo_scope(options).order("#{distance_column_name} asc").limit(1)
      end
      alias nearest closest

      def farthest(options = {})
        geo_scope(options).order("#{distance_column_name} desc").limit(1)
      end

      def geo_scope(options = {})
        arel = self.is_a?(Relation) ? self : self.scoped
        
        origin = extract_origin_from_options!(options)
        units = extract_units_from_options!(options)
        formula = extract_formula_from_options!(options)
        bounds = extract_bounds_from_options!(options)

        if origin || bounds
          bounds ||= formulate_bounds_from_distance(options, origin, units)

          if origin
            arel.distance_formula = distance_formula = distance_sql(origin, units, formula)
            
            if arel.select_values.blank?
              star_select = Arel::SqlLiteral.new(arel.quoted_table_name + '.*')
              arel = arel.select(star_select)
            end
            
            distance_select = Arel::SqlLiteral.new("#{distance_formula} AS #{distance_column_name}")
            arel = arel.select(distance_select)
          end

          if bounds
            bound_conditions = bound_conditions(bounds)
            arel = arel.where(bound_conditions) if bound_conditions
          end

          distance_conditions = distance_conditions(options)
          arel = arel.where(distance_conditions) if distance_conditions
          
          if self.through
            arel = arel.includes(self.through)
          end
        end

        arel
      end
      
    private
      # Override ActiveRecord::Base.relation to return an instance of Geokit::ActsAsMappable::Relation.
      # TODO: Do we need to override JoinDependency#relation too?
      def relation
        @relation ||= Relation.new(self, arel_table)
        finder_needs_type_condition? ? @relation.where(type_condition) : @relation
      end
    
      # If it's a :within query, add a bounding box to improve performance.
      # This only gets called if a :bounds argument is not otherwise supplied.
      def formulate_bounds_from_distance(options, origin, units)
        distance = options[:within] if options.has_key?(:within)
        distance = options[:range].last-(options[:range].exclude_end? ? 1 : 0) if options.has_key?(:range)
        if distance
          res=Geokit::Bounds.from_point_and_radius(origin,distance,:units=>units)
        else
          nil
        end
      end

      def distance_conditions(options)
        res = if options.has_key?(:within)
          "#{distance_column_name} <= #{options[:within]}"
        elsif options.has_key?(:beyond)
          "#{distance_column_name} > #{options[:beyond]}"
        elsif options.has_key?(:range)
          "#{distance_column_name} >= #{options[:range].first} AND #{distance_column_name} <#{'=' unless options[:range].exclude_end?} #{options[:range].last}"
        end
        Arel::SqlLiteral.new("(#{res})") if res.present?
      end

      def bound_conditions(bounds)
        sw,ne = bounds.sw, bounds.ne
        lng_sql = bounds.crosses_meridian? ? "(#{qualified_lng_column_name}<#{ne.lng} OR #{qualified_lng_column_name}>#{sw.lng})" : "#{qualified_lng_column_name}>#{sw.lng} AND #{qualified_lng_column_name}<#{ne.lng}"
        res = "#{qualified_lat_column_name}>#{sw.lat} AND #{qualified_lat_column_name}<#{ne.lat} AND #{lng_sql}"
        Arel::SqlLiteral.new("(#{res})") if res.present?
      end

      # Extracts the origin instance out of the options if it exists and returns
      # it.  If there is no origin, looks for latitude and longitude values to
      # create an origin.  The side-effect of the method is to remove these
      # option keys from the hash.
      def extract_origin_from_options!(options)
        if origin = options.delete(:origin)
          normalize_point_to_lat_lng(origin)
        end
      end

      # Extract the units out of the options if it exists and returns it.  If
      # there is no :units key, it uses the default.  The side effect of the
      # method is to remove the :units key from the options hash.
      def extract_units_from_options!(options)
        options.delete(:units) || default_units
      end

      # Extract the formula out of the options if it exists and returns it.  If
      # there is no :formula key, it uses the default.  The side effect of the
      # method is to remove the :formula key from the options hash.
      def extract_formula_from_options!(options)
        options.delete(:formula) || default_formula
      end

      def extract_bounds_from_options!(options)
        if bounds = options.delete(:bounds)
          Geokit::Bounds.normalize(bounds)
        end
      end

      # Geocode IP address.
      def geocode_ip_address(origin)
        geo_location = Geokit::Geocoders::MultiGeocoder.geocode(origin)
        return geo_location if geo_location.success
        raise Geokit::Geocoders::GeocodeError
      end

      # Given a point in a variety of (an address to geocode,
      # an array of [lat,lng], or an object with appropriate lat/lng methods, an IP addres)
      # this method will normalize it into a Geokit::LatLng instance. The only thing this
      # method adds on top of LatLng#normalize is handling of IP addresses
      def normalize_point_to_lat_lng(point)
        res = geocode_ip_address(point) if point.is_a?(String) && /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})?$/.match(point)
        res = Geokit::LatLng.normalize(point) unless res
        res
      end
      
      # Returns the distance calculation to be used as a display column or a condition.  This
      # is provide for anyone wanting access to the raw SQL.
      def distance_sql(origin, units=default_units, formula=default_formula)
        case formula
        when :sphere
          sql = sphere_distance_sql(origin, units)
        when :flat
          sql = flat_distance_sql(origin, units)
        end
        sql
      end
      
      # Returns the distance SQL using the spherical world formula (Haversine).  The SQL is tuned
      # to the database in use.
      def sphere_distance_sql(origin, units)
        lat = deg2rad(origin.lat)
        lng = deg2rad(origin.lng)
        multiplier = units_sphere_multiplier(units)

        adapter.sphere_distance_sql(lat, lng, multiplier) if adapter
      end

      # Returns the distance SQL using the flat-world formula (Phythagorean Theory).  The SQL is tuned
      # to the database in use.
      def flat_distance_sql(origin, units)
        lat_degree_units = units_per_latitude_degree(units)
        lng_degree_units = units_per_longitude_degree(origin.lat, units)

        adapter.flat_distance_sql(origin, lat_degree_units, lng_degree_units)
      end
    end # ClassMethods

  end # ActsAsMappable
end # Geokit