// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// AutoMapprGenerator
// **************************************************************************

// ignore_for_file: type=lint, unnecessary_cast, unused_local_variable

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:auto_mappr_annotation/auto_mappr_annotation.dart' as _i1;
import 'package:dawarich/features/stats/data/data_transfer_objects/countries/visited_city_dto.dart'
    as _i6;
import 'package:dawarich/features/stats/data/data_transfer_objects/countries/visited_countries_dto.dart'
    as _i2;
import 'package:dawarich/features/stats/data/data_transfer_objects/countries/visited_country_dto.dart'
    as _i4;
import 'package:dawarich/features/stats/data/mappers/countries_mapper.dart'
    as _i8;
import 'package:dawarich/features/stats/domain/countries/visited_city.dart'
    as _i7;
import 'package:dawarich/features/stats/domain/countries/visited_countries.dart'
    as _i3;
import 'package:dawarich/features/stats/domain/countries/visited_country.dart'
    as _i5;

/// {@template package:dawarich/features/stats/data/mappers/countries_mapper.dart}
/// Available mappings:
/// - `VisitedCountriesDto` → `VisitedCountries`.
/// - `VisitedCountryDto` → `VisitedCountry`.
/// - `VisitedCityDto` → `VisitedCity`.
/// {@endtemplate}
class $VisitedCountriesDataMapper implements _i1.AutoMapprInterface {
  const $VisitedCountriesDataMapper();

  Type _typeOf<T>() => T;

  List<_i1.AutoMapprInterface> get _delegates => const [];

  /// {@macro AutoMapprInterface:canConvert}
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  bool canConvert<SOURCE, TARGET>({bool recursive = true}) {
    final sourceTypeOf = _typeOf<SOURCE>();
    final targetTypeOf = _typeOf<TARGET>();
    if ((sourceTypeOf == _typeOf<_i2.VisitedCountriesDto>() ||
            sourceTypeOf == _typeOf<_i2.VisitedCountriesDto?>()) &&
        (targetTypeOf == _typeOf<_i3.VisitedCountries>() ||
            targetTypeOf == _typeOf<_i3.VisitedCountries?>())) {
      return true;
    }
    if ((sourceTypeOf == _typeOf<_i4.VisitedCountryDto>() ||
            sourceTypeOf == _typeOf<_i4.VisitedCountryDto?>()) &&
        (targetTypeOf == _typeOf<_i5.VisitedCountry>() ||
            targetTypeOf == _typeOf<_i5.VisitedCountry?>())) {
      return true;
    }
    if ((sourceTypeOf == _typeOf<_i6.VisitedCityDto>() ||
            sourceTypeOf == _typeOf<_i6.VisitedCityDto?>()) &&
        (targetTypeOf == _typeOf<_i7.VisitedCity>() ||
            targetTypeOf == _typeOf<_i7.VisitedCity?>())) {
      return true;
    }
    if (recursive) {
      for (final mappr in _delegates) {
        if (mappr.canConvert<SOURCE, TARGET>()) {
          return true;
        }
      }
    }
    return false;
  }

  /// {@macro AutoMapprInterface:convert}
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  TARGET convert<SOURCE, TARGET>(SOURCE? model) {
    if (canConvert<SOURCE, TARGET>(recursive: false)) {
      return _convert(model)!;
    }
    for (final mappr in _delegates) {
      if (mappr.canConvert<SOURCE, TARGET>()) {
        return mappr.convert(model)!;
      }
    }

    throw Exception('No ${_typeOf<SOURCE>()} -> ${_typeOf<TARGET>()} mapping.');
  }

  /// {@macro AutoMapprInterface:tryConvert}
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  TARGET? tryConvert<SOURCE, TARGET>(
    SOURCE? model, {
    void Function(Object error, StackTrace stackTrace, SOURCE? source)?
        onMappingError,
  }) {
    if (canConvert<SOURCE, TARGET>(recursive: false)) {
      return _safeConvert(
        model,
        onMappingError: onMappingError,
      );
    }
    for (final mappr in _delegates) {
      if (mappr.canConvert<SOURCE, TARGET>()) {
        return mappr.tryConvert(
          model,
          onMappingError: onMappingError,
        );
      }
    }

    return null;
  }

  /// {@macro AutoMapprInterface:convertIterable}
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  Iterable<TARGET> convertIterable<SOURCE, TARGET>(Iterable<SOURCE?> model) {
    if (canConvert<SOURCE, TARGET>(recursive: false)) {
      return model.map<TARGET>((item) => _convert(item)!);
    }
    for (final mappr in _delegates) {
      if (mappr.canConvert<SOURCE, TARGET>()) {
        return mappr.convertIterable(model);
      }
    }

    throw Exception('No ${_typeOf<SOURCE>()} -> ${_typeOf<TARGET>()} mapping.');
  }

  /// For iterable items, converts from SOURCE to TARGET if such mapping is configured, into Iterable.
  ///
  /// When an item in the source iterable is null, uses `whenSourceIsNull` if defined or null
  ///
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  Iterable<TARGET?> tryConvertIterable<SOURCE, TARGET>(
    Iterable<SOURCE?> model, {
    void Function(Object error, StackTrace stackTrace, SOURCE? source)?
        onMappingError,
  }) {
    if (canConvert<SOURCE, TARGET>(recursive: false)) {
      return model.map<TARGET?>(
          (item) => _safeConvert(item, onMappingError: onMappingError));
    }
    for (final mappr in _delegates) {
      if (mappr.canConvert<SOURCE, TARGET>()) {
        return mappr.tryConvertIterable(
          model,
          onMappingError: onMappingError,
        );
      }
    }

    throw Exception('No ${_typeOf<SOURCE>()} -> ${_typeOf<TARGET>()} mapping.');
  }

  /// {@macro AutoMapprInterface:convertList}
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  List<TARGET> convertList<SOURCE, TARGET>(Iterable<SOURCE?> model) {
    if (canConvert<SOURCE, TARGET>(recursive: false)) {
      return convertIterable<SOURCE, TARGET>(model).toList();
    }
    for (final mappr in _delegates) {
      if (mappr.canConvert<SOURCE, TARGET>()) {
        return mappr.convertList(model);
      }
    }

    throw Exception('No ${_typeOf<SOURCE>()} -> ${_typeOf<TARGET>()} mapping.');
  }

  /// For iterable items, converts from SOURCE to TARGET if such mapping is configured, into List.
  ///
  /// When an item in the source iterable is null, uses `whenSourceIsNull` if defined or null
  ///
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  List<TARGET?> tryConvertList<SOURCE, TARGET>(
    Iterable<SOURCE?> model, {
    void Function(Object error, StackTrace stackTrace, SOURCE? source)?
        onMappingError,
  }) {
    if (canConvert<SOURCE, TARGET>(recursive: false)) {
      return tryConvertIterable<SOURCE, TARGET>(
        model,
        onMappingError: onMappingError,
      ).toList();
    }
    for (final mappr in _delegates) {
      if (mappr.canConvert<SOURCE, TARGET>()) {
        return mappr.tryConvertList(
          model,
          onMappingError: onMappingError,
        );
      }
    }

    throw Exception('No ${_typeOf<SOURCE>()} -> ${_typeOf<TARGET>()} mapping.');
  }

  /// {@macro AutoMapprInterface:convertSet}
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  Set<TARGET> convertSet<SOURCE, TARGET>(Iterable<SOURCE?> model) {
    if (canConvert<SOURCE, TARGET>(recursive: false)) {
      return convertIterable<SOURCE, TARGET>(model).toSet();
    }
    for (final mappr in _delegates) {
      if (mappr.canConvert<SOURCE, TARGET>()) {
        return mappr.convertSet(model);
      }
    }

    throw Exception('No ${_typeOf<SOURCE>()} -> ${_typeOf<TARGET>()} mapping.');
  }

  /// For iterable items, converts from SOURCE to TARGET if such mapping is configured, into Set.
  ///
  /// When an item in the source iterable is null, uses `whenSourceIsNull` if defined or null
  ///
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  Set<TARGET?> tryConvertSet<SOURCE, TARGET>(
    Iterable<SOURCE?> model, {
    void Function(Object error, StackTrace stackTrace, SOURCE? source)?
        onMappingError,
  }) {
    if (canConvert<SOURCE, TARGET>(recursive: false)) {
      return tryConvertIterable<SOURCE, TARGET>(
        model,
        onMappingError: onMappingError,
      ).toSet();
    }
    for (final mappr in _delegates) {
      if (mappr.canConvert<SOURCE, TARGET>()) {
        return mappr.tryConvertSet(
          model,
          onMappingError: onMappingError,
        );
      }
    }

    throw Exception('No ${_typeOf<SOURCE>()} -> ${_typeOf<TARGET>()} mapping.');
  }

  TARGET? _convert<SOURCE, TARGET>(
    SOURCE? model, {
    bool canReturnNull = false,
  }) {
    final sourceTypeOf = _typeOf<SOURCE>();
    final targetTypeOf = _typeOf<TARGET>();
    if ((sourceTypeOf == _typeOf<_i2.VisitedCountriesDto>() ||
            sourceTypeOf == _typeOf<_i2.VisitedCountriesDto?>()) &&
        (targetTypeOf == _typeOf<_i3.VisitedCountries>() ||
            targetTypeOf == _typeOf<_i3.VisitedCountries?>())) {
      if (canReturnNull && model == null) {
        return null;
      }
      return (_map__i2$VisitedCountriesDto_To__i3$VisitedCountries(
          (model as _i2.VisitedCountriesDto?)) as TARGET);
    }
    if ((sourceTypeOf == _typeOf<_i4.VisitedCountryDto>() ||
            sourceTypeOf == _typeOf<_i4.VisitedCountryDto?>()) &&
        (targetTypeOf == _typeOf<_i5.VisitedCountry>() ||
            targetTypeOf == _typeOf<_i5.VisitedCountry?>())) {
      if (canReturnNull && model == null) {
        return null;
      }
      return (_map__i4$VisitedCountryDto_To__i5$VisitedCountry(
          (model as _i4.VisitedCountryDto?)) as TARGET);
    }
    if ((sourceTypeOf == _typeOf<_i6.VisitedCityDto>() ||
            sourceTypeOf == _typeOf<_i6.VisitedCityDto?>()) &&
        (targetTypeOf == _typeOf<_i7.VisitedCity>() ||
            targetTypeOf == _typeOf<_i7.VisitedCity?>())) {
      if (canReturnNull && model == null) {
        return null;
      }
      return (_map__i6$VisitedCityDto_To__i7$VisitedCity(
          (model as _i6.VisitedCityDto?)) as TARGET);
    }
    throw Exception('No ${model.runtimeType} -> $targetTypeOf mapping.');
  }

  TARGET? _safeConvert<SOURCE, TARGET>(
    SOURCE? model, {
    void Function(Object error, StackTrace stackTrace, SOURCE? source)?
        onMappingError,
  }) {
    if (!useSafeMapping<SOURCE, TARGET>()) {
      return _convert(
        model,
        canReturnNull: true,
      );
    }
    try {
      return _convert(
        model,
        canReturnNull: true,
      );
    } catch (e, s) {
      onMappingError?.call(e, s, model);
      return null;
    }
  }

  /// {@macro AutoMapprInterface:useSafeMapping}
  /// {@macro package:dawarich/features/stats/data/mappers/countries_mapper.dart}
  @override
  bool useSafeMapping<SOURCE, TARGET>() {
    return false;
  }

  _i3.VisitedCountries _map__i2$VisitedCountriesDto_To__i3$VisitedCountries(
      _i2.VisitedCountriesDto? input) {
    final model = input;
    if (model == null) {
      throw Exception(
          r'Mapping VisitedCountriesDto → VisitedCountries failed because VisitedCountriesDto was null, and no default value was provided. '
          r'Consider setting the whenSourceIsNull parameter on the MapType<VisitedCountriesDto, VisitedCountries> to handle null values during mapping.');
    }
    return _i3.VisitedCountries(
        data: model.data
            .map<_i5.VisitedCountry>((value) =>
                _map__i4$VisitedCountryDto_To__i5$VisitedCountry(value))
            .toList());
  }

  _i5.VisitedCountry _map__i4$VisitedCountryDto_To__i5$VisitedCountry(
      _i4.VisitedCountryDto? input) {
    final model = input;
    if (model == null) {
      throw Exception(
          r'Mapping VisitedCountryDto → VisitedCountry failed because VisitedCountryDto was null, and no default value was provided. '
          r'Consider setting the whenSourceIsNull parameter on the MapType<VisitedCountryDto, VisitedCountry> to handle null values during mapping.');
    }
    return _i5.VisitedCountry(
      country: model.country,
      cities: model.cities
          .map<_i7.VisitedCity>(
              (value) => _map__i6$VisitedCityDto_To__i7$VisitedCity(value))
          .toList(),
    );
  }

  _i7.VisitedCity _map__i6$VisitedCityDto_To__i7$VisitedCity(
      _i6.VisitedCityDto? input) {
    final model = input;
    if (model == null) {
      throw Exception(
          r'Mapping VisitedCityDto → VisitedCity failed because VisitedCityDto was null, and no default value was provided. '
          r'Consider setting the whenSourceIsNull parameter on the MapType<VisitedCityDto, VisitedCity> to handle null values during mapping.');
    }
    return _i7.VisitedCity(
      city: model.city,
      points: model.points,
      timestamp:
          (_i8.VisitedCountriesDataMapper.unixSecondsToDateTime(model.timestamp)
              as DateTime),
      stayedFor:
          (_i8.VisitedCountriesDataMapper.secondsToDuration(model.stayedFor)
              as Duration),
    );
  }
}
