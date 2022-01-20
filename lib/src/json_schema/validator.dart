// Copyright 2013-2018 Workiva Inc.
//
// Licensed under the Boost Software License (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.boost.org/LICENSE_1_0.txt
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// This software or document includes material copied from or derived
// from JSON-Schema-Test-Suite (https://github.com/json-schema-org/JSON-Schema-Test-Suite),
// Copyright (c) 2012 Julian Berman, which is licensed under the following terms:
//
//     Copyright (c) 2012 Julian Berman
//
//     Permission is hereby granted, free of charge, to any person obtaining a copy
//     of this software and associated documentation files (the "Software"), to deal
//     in the Software without restriction, including without limitation the rights
//     to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//     copies of the Software, and to permit persons to whom the Software is
//     furnished to do so, subject to the following conditions:
//
//     The above copyright notice and this permission notice shall be included in
//     all copies or substantial portions of the Software.
//
//     THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//     IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//     FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//     AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//     LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//     OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//     THE SOFTWARE.

import 'dart:convert';
import 'dart:math';

import 'package:json_schema/src/json_schema/constants.dart';
import 'package:json_schema/src/json_schema/json_schema.dart';
import 'package:json_schema/src/json_schema/schema_type.dart';
import 'package:json_schema/src/json_schema/utils.dart';
import 'package:json_schema/src/json_schema/global_platform_functions.dart'
    show defaultValidators;

class Instance {
  Instance(dynamic data, {String path = ''}) {
    this.data = data;
    this.path = path;
  }

  dynamic data;
  String path;

  @override
  toString() => data.toString();
}

class ValidationError {
  ValidationError._(this.instancePath, this.schemaPath, this.message);

  /// Path in the instance data to the key where this error occurred
  String instancePath;

  /// Path to the key in the schema containing the rule that produced this error
  String schemaPath;

  /// A human-readable message explaining why validation failed
  String message;

  @override
  toString() => '${instancePath.isEmpty ? '# (root)' : instancePath}: $message';
}

/// Initialized with schema, validates instances against it
class Validator {
  final JsonSchema _rootSchema;
  List<ValidationError> _errors = [];
  bool _reportMultipleErrors;

  Validator(this._rootSchema);

  List<String> get errors => _errors.map((e) => e.toString()).toList();

  List<ValidationError> get errorObjects => _errors;

  bool _validateFormats;

  /// Validate the [instance] against the this validator's schema
  bool validate(dynamic instance,
      {bool reportMultipleErrors = false,
      bool parseJson = false,
      bool validateFormats}) {
    // _logger.info('Validating ${instance.runtimeType}:$instance on ${_rootSchema}'); TODO: re-add logger

    if (validateFormats == null) {
      // Reference: https://json-schema.org/draft/2019-09/release-notes.html#format-vocabulary
      if ([SchemaVersion.draft4, SchemaVersion.draft6, SchemaVersion.draft7]
          .contains(_rootSchema.schemaVersion)) {
        // By default, formats are validated on a best-effort basis from draft4 through draft7.
        validateFormats = true;
      } else {
        // Starting with Draft 2019-09, formats shouldn't be validated by default.
        validateFormats = false;
      }
    }
    _validateFormats = validateFormats;

    dynamic data = instance;
    if (parseJson && instance is String) {
      try {
        data = json.decode(instance);
      } catch (e) {
        throw ArgumentError(
            'JSON instance provided to validate is not valid JSON.');
      }
    }

    _reportMultipleErrors = reportMultipleErrors;
    _errors = [];
    if (!_reportMultipleErrors) {
      try {
        _validate(_rootSchema, data);
        return true;
      } on FormatException {
        return false;
      } catch (e) {
        // _logger.shout('Unexpected Exception: $e'); TODO: re-add logger
        return false;
      }
    }

    _validate(_rootSchema, data);
    return _errors.length == 0;
  }

  static bool _typeMatch(SchemaType type, JsonSchema schema, dynamic instance) {
    switch (type) {
      case SchemaType.object:
        return instance is Map;
      case SchemaType.string:
        return instance is String;
      case SchemaType.integer:
        return instance is int ||
            ([SchemaVersion.draft6, SchemaVersion.draft7]
                    .contains(schema.schemaVersion) &&
                instance is num &&
                instance.remainder(1) == 0);
      case SchemaType.number:
        return instance is num;
      case SchemaType.array:
        return instance is List;
      case SchemaType.boolean:
        return instance is bool;
      case SchemaType.nullValue:
        return instance == null;
    }
    return false;
  }

  void _numberValidation(JsonSchema schema, Instance instance) {
    final num n = instance.data;

    final maximum = schema.maximum;
    final minimum = schema.minimum;
    final exclusiveMaximum = schema.exclusiveMaximum;
    final exclusiveMinimum = schema.exclusiveMinimum;

    if (exclusiveMaximum != null) {
      if (n >= exclusiveMaximum) {
        _err('exclusiveMaximum exceeded ($n >= $exclusiveMaximum)',
            instance.path, schema.path);
      }
    } else if (maximum != null) {
      if (n > maximum) {
        _err('maximum exceeded ($n > $maximum)', instance.path, schema.path);
      }
    }

    if (exclusiveMinimum != null) {
      if (n <= exclusiveMinimum) {
        _err('exclusiveMinimum violated ($n <= $exclusiveMinimum)',
            instance.path, schema.path);
      }
    } else if (minimum != null) {
      if (n < minimum) {
        _err('minimum violated ($n < $minimum)', instance.path, schema.path);
      }
    }

    final multipleOf = schema.multipleOf;
    if (multipleOf != null) {
      if (multipleOf is int && n is int) {
        if (0 != n % multipleOf) {
          _err('multipleOf violated ($n % $multipleOf)', instance.path,
              schema.path);
        }
      } else {
        final double result = n / multipleOf;
        if (result.truncate() != result) {
          _err('multipleOf violated ($n % $multipleOf)', instance.path,
              schema.path);
        }
      }
    }
  }

  void _typeValidation(JsonSchema schema, Instance instance) {
    final typeList = schema.typeList;
    if (typeList != null && typeList.length > 0) {
      if (!typeList.any((type) => _typeMatch(type, schema, instance.data))) {
        if (instance.data is Iterable) {
          _err(
              '[type] wanted one of ${typeList.toString()}, but got \'${instance.data.runtimeType.toString()}\'',
              instance.path,
              schema.path);
        } else {
          _err(
              '[type] wanted one of ${typeList.toString()}, but got \'${instance.data.runtimeType.toString()}\' (value: ${instance.toString()})',
              instance.path,
              schema.path);
        }
      }
    }
  }

  void _constValidation(JsonSchema schema, Instance instance) {
    if (schema.hasConst &&
        !JsonSchemaUtils.jsonEqual(instance.data, schema.constValue)) {
      _err('const violated ${instance}', instance.path, schema.path);
    }
  }

  void _enumValidation(JsonSchema schema, Instance instance) {
    final enumValues = schema.enumValues;
    if (enumValues.length > 0) {
      try {
        enumValues
            .singleWhere((v) => JsonSchemaUtils.jsonEqual(instance.data, v));
      } on StateError {
        _err(
            '[enum] got \'${instance}\', but wanted one of ${enumValues.toString()}',
            instance.path,
            schema.path);
      }
    }
  }

  void _stringValidation(JsonSchema schema, Instance instance) {
    final actual = instance.data.runes.length;
    final minLength = schema.minLength;
    final maxLength = schema.maxLength;
    if (maxLength is int && actual > maxLength) {
      _err('maxLength exceeded ($instance vs $maxLength)', instance.path,
          schema.path);
    } else if (minLength is int && actual < minLength) {
      _err('minLength violated ($instance vs $minLength)', instance.path,
          schema.path);
    }
    final pattern = schema.pattern;
    if (pattern != null && !pattern.hasMatch(instance.data)) {
      _err('pattern violated ($instance vs $pattern)', instance.path,
          schema.path);
    }
  }

  void _itemsValidation(JsonSchema schema, Instance instance) {
    final int actual = instance.data.length;

    final singleSchema = schema.items;
    if (singleSchema != null) {
      instance.data.asMap().forEach((index, item) {
        final itemInstance = Instance(item, path: '${instance.path}/$index');
        _validate(singleSchema, itemInstance);
      });
    } else {
      final items = schema.itemsList;

      if (items != null) {
        final expected = items.length;
        final end = min(expected, actual);
        for (int i = 0; i < end; i++) {
          assert(items[i] != null);
          final itemInstance =
              Instance(instance.data[i], path: '${instance.path}/$i');
          _validate(items[i], itemInstance);
        }
        if (schema.additionalItemsSchema != null) {
          for (int i = end; i < actual; i++) {
            final itemInstance =
                Instance(instance.data[i], path: '${instance.path}/$i');
            _validate(schema.additionalItemsSchema, itemInstance);
          }
        } else if (schema.additionalItemsBool != null) {
          if (!schema.additionalItemsBool && actual > end) {
            _err('additionalItems false', instance.path,
                schema.path + '/additionalItems');
          }
        }
      }
    }

    final maxItems = schema.maxItems;
    final minItems = schema.minItems;
    if (maxItems is int && actual > maxItems) {
      _err('maxItems exceeded ($actual vs $maxItems)', instance.path,
          schema.path);
    } else if (schema.minItems is int && actual < schema.minItems) {
      _err('minItems violated ($actual vs $minItems)', instance.path,
          schema.path);
    }

    if (schema.uniqueItems) {
      final end = instance.data.length;
      final penultimate = end - 1;
      for (int i = 0; i < penultimate; i++) {
        for (int j = i + 1; j < end; j++) {
          if (JsonSchemaUtils.jsonEqual(instance.data[i], instance.data[j])) {
            _err('uniqueItems violated: $instance [$i]==[$j]', instance.path,
                schema.path);
          }
        }
      }
    }

    if (schema.contains != null) {
      if (!instance.data.any((item) => Validator(schema.contains)
          .validate(item, reportMultipleErrors: _reportMultipleErrors))) {
        _err('contains violated: $instance', instance.path, schema.path);
      }
    }
  }

  void _validateAllOf(JsonSchema schema, Instance instance) {
    final schemas = schema.allOf.map(
      (s) => _validateWithErrors(s, instance,
          reportMultipleErrors: _reportMultipleErrors),
    );
    if (!schemas.every((errors) => errors.isEmpty)) {
      _err(
          '${schema.path}: An \'allOf\' rule is violated. One or more schemas is failed.',
          instance.path,
          schema.path + '/allOf');
      schemas.forEach(_errors.addAll);
    }
  }

  void _validateAnyOf(JsonSchema schema, Instance instance) {
    final schemas = schema.anyOf.map(
      (s) => _validateWithErrors(s, instance,
          reportMultipleErrors: _reportMultipleErrors),
    );
    if (!schemas.any((errors) => errors.isEmpty)) {
      _err(
          '${schema.path}/anyOf: An \'anyOf\' rule is violated. All schemas is failed.',
          instance.path,
          schema.path + '/anyOf');
      schemas.forEach(_errors.addAll);
    }
  }

  void _validateOneOf(JsonSchema schema, Instance instance) {
    final schemas = schema.oneOf.map((s) => _validateWithErrors(s, instance,
        reportMultipleErrors: _reportMultipleErrors));

    try {
      schemas.singleWhere((errors) => errors.isEmpty);
    } on StateError catch (error) {
      schemas.forEach(_errors.addAll);
      _err(
          '${schema.path}/oneOf: An \'oneOf\' rule is violated. Two or more schemas have been successfully validated.',
          instance.path,
          schema.path + '/oneOf');
      schemas.forEach(_errors.addAll);
    }
  }

  Iterable<ValidationError> _validateWithErrors(
      JsonSchema schema, dynamic instance,
      {bool reportMultipleErrors,
      bool parseJson = false,
      bool validateFormats}) {
    final validator = Validator(schema);
    validator.validate(instance,
        reportMultipleErrors: true,
        parseJson: parseJson,
        validateFormats: validateFormats);
    return validator.errorObjects;
  }

  void _validateNot(JsonSchema schema, Instance instance) {
    if (Validator(schema.notSchema)
        .validate(instance, reportMultipleErrors: _reportMultipleErrors)) {
      // TODO: deal with .notSchema
      _err('${schema.notSchema.path}: not violated', instance.path,
          schema.notSchema.path);
    }
  }

  void _validateFormat(JsonSchema schema, Instance instance) {
    if (!_validateFormats) return;
    // Non-strings in formats should be ignored.
    if (instance.data is! String) return;

    switch (schema.format) {
      case 'date-time':
        try {
          DateTime.parse(instance.data);
        } catch (e) {
          _err('"date-time" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'time':
        // regex is an allowed format in draft3, out in draft4/6, back in draft7.
        // Since we don't support draft3, just draft7 is needed here.
        if (SchemaVersion.draft7 != schema.schemaVersion) return;
        if (JsonSchemaValidationRegexes.fullTime.firstMatch(instance.data) ==
            null) {
          _err('"time" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'date':
        // regex is an allowed format in draft3, out in draft4/6, back in draft7.
        // Since we don't support draft3, just draft7 is needed here.
        if (SchemaVersion.draft7 != schema.schemaVersion) return;
        if (JsonSchemaValidationRegexes.fullDate.firstMatch(instance.data) ==
            null) {
          _err('"date" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'uri':
        final isValid = defaultValidators.uriValidator ?? (_) => false;

        if (!isValid(instance.data)) {
          _err('"uri" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'iri':
        if (SchemaVersion.draft7 != schema.schemaVersion) return;
        // Dart's URI class supports parsing IRIs, so we can use the same validator
        final isValid = defaultValidators.uriValidator ?? (_) => false;

        if (!isValid(instance.data)) {
          _err('"uri" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'iri-reference':
        if (SchemaVersion.draft7 != schema.schemaVersion) return;

        // Dart's URI class supports parsing IRIs, so we can use the same validator
        final isValid = defaultValidators.uriReferenceValidator ?? (_) => false;

        if (!isValid(instance.data)) {
          _err('"iri-reference" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'uri-reference':
        if (![SchemaVersion.draft6, SchemaVersion.draft7]
            .contains(schema.schemaVersion)) return;
        final isValid = defaultValidators.uriReferenceValidator ?? (_) => false;

        if (!isValid(instance.data)) {
          _err('"uri-reference" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'uri-template':
        if (![SchemaVersion.draft6, SchemaVersion.draft7]
            .contains(schema.schemaVersion)) return;
        final isValid = defaultValidators.uriTemplateValidator ?? (_) => false;

        if (!isValid(instance.data)) {
          _err('"uri-template" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'email':
        final isValid = defaultValidators.emailValidator ?? (_) => false;

        if (!isValid(instance.data)) {
          _err('"email" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'idn-email':
        // No maintained dart packages exist to validate RFC6531,
        // and it's too complex for a regex, so best effort is to pass for now.
        break;
      case 'ipv4':
        if (JsonSchemaValidationRegexes.ipv4.firstMatch(instance.data) ==
            null) {
          _err('"ipv4" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'ipv6':
        if (JsonSchemaValidationRegexes.ipv6.firstMatch(instance.data) ==
            null) {
          _err('ipv6" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'hostname':
        if (JsonSchemaValidationRegexes.hostname.firstMatch(instance.data) ==
            null) {
          _err('"hostname" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'idn-hostname':
        if (SchemaVersion.draft7 != schema.schemaVersion) return;
        if (JsonSchemaValidationRegexes.idnHostname.firstMatch(instance.data) ==
            null) {
          _err('"idn-hostname" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'json-pointer':
        if (![SchemaVersion.draft6, SchemaVersion.draft7]
            .contains(schema.schemaVersion)) return;
        if (JsonSchemaValidationRegexes.jsonPointer.firstMatch(instance.data) ==
            null) {
          _err('json-pointer" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      case 'relative-json-pointer':
        if (SchemaVersion.draft7 != schema.schemaVersion) return;
        if (JsonSchemaValidationRegexes.relativeJsonPointer
                .firstMatch(instance.data) ==
            null) {
          _err('relative-json-pointer" format not accepted $instance',
              instance.path, schema.path);
        }
        break;
      case 'regex':
        // regex is an allowed format in draft3, out in draft4/6, back in draft7.
        // Since we don't support draft3, just draft7 is needed here.
        if (SchemaVersion.draft7 != schema.schemaVersion) return;
        try {
          RegExp(instance.data, unicode: true);
        } catch (e) {
          _err('"regex" format not accepted $instance', instance.path,
              schema.path);
        }
        break;
      default:
        // Don't attempt to validate unknown formats.
        break;
    }
  }

  void _objectPropertyValidation(JsonSchema schema, Instance instance) {
    final propMustValidate = schema.additionalPropertiesBool != null &&
        !schema.additionalPropertiesBool;

    instance.data.forEach((k, v) {
      // Validate property names against the provided schema, if any.
      if (schema.propertyNamesSchema != null) {
        _validate(schema.propertyNamesSchema, k);
      }

      final newInstance = Instance(v, path: '${instance.path}/$k');

      bool propCovered = false;
      final JsonSchema propSchema = schema.properties[k];
      if (propSchema != null) {
        assert(propSchema != null);
        _validate(propSchema, newInstance);
        propCovered = true;
      }

      schema.patternProperties.forEach((regex, patternSchema) {
        if (regex.hasMatch(k)) {
          assert(patternSchema != null);
          _validate(patternSchema, newInstance);
          propCovered = true;
        }
      });

      if (!propCovered) {
        if (schema.additionalPropertiesSchema != null) {
          _validate(schema.additionalPropertiesSchema, newInstance);
        } else if (propMustValidate) {
          _err('unallowed additional property $k', instance.path,
              schema.path + '/additionalProperties');
        }
      }
    });
  }

  void _propertyDependenciesValidation(JsonSchema schema, Instance instance) {
    schema.propertyDependencies.forEach((k, dependencies) {
      if (instance.data.containsKey(k)) {
        if (!dependencies.every((prop) => instance.data.containsKey(prop))) {
          _err('prop $k => $dependencies required', instance.path,
              schema.path + '/dependencies');
        }
      }
    });
  }

  void _schemaDependenciesValidation(JsonSchema schema, Instance instance) {
    schema.schemaDependencies.forEach((k, otherSchema) {
      if (instance.data.containsKey(k)) {
        if (!Validator(otherSchema)
            .validate(instance, reportMultipleErrors: _reportMultipleErrors)) {
          _err('prop $k violated schema dependency', instance.path,
              otherSchema.path);
        }
      }
    });
  }

  void _objectValidation(JsonSchema schema, Instance instance) {
    // Min / Max Props
    final numProps = instance.data.length;
    final minProps = schema.minProperties;
    final maxProps = schema.maxProperties;
    if (numProps < minProps) {
      _err('minProperties violated (${numProps} < ${minProps})', instance.path,
          schema.path);
    } else if (maxProps != null && numProps > maxProps) {
      _err('maxProperties violated (${numProps} > ${maxProps})', instance.path,
          schema.path);
    }

    // Required Properties
    if (schema.requiredProperties != null) {
      schema.requiredProperties.forEach((prop) {
        if (!instance.data.containsKey(prop)) {
          _err('required prop missing: \'${prop}\'', instance.path,
              schema.path + '/required');
        }
      });
    }

    _objectPropertyValidation(schema, instance);

    if (schema.propertyDependencies != null)
      _propertyDependenciesValidation(schema, instance);

    if (schema.schemaDependencies != null)
      _schemaDependenciesValidation(schema, instance);
  }

  void _validate(JsonSchema schema, dynamic instance) {
    if (instance is! Instance) {
      instance = Instance(instance);
    }

    /// If the [JsonSchema] being validated is a ref, pull the ref
    /// from the [refMap] instead.
    while (schema.ref != null) {
      schema = schema.resolvePath(schema.ref);
    }

    /// If the [JsonSchema] is a bool, always return this value.
    if (schema.schemaBool != null) {
      if (schema.schemaBool == false) {
        _err(
            'schema is a boolean == false, this schema will never validate. Instance: $instance',
            instance.path,
            schema.path);
      }
      return;
    }

    _ifThenElseValidation(schema, instance);
    _typeValidation(schema, instance);
    _constValidation(schema, instance);
    _enumValidation(schema, instance);
    if (instance.data is List) _itemsValidation(schema, instance);
    if (instance.data is String) _stringValidation(schema, instance);
    if (instance.data is num) _numberValidation(schema, instance);
    if (schema.allOf.length > 0) _validateAllOf(schema, instance);
    if (schema.anyOf.length > 0) _validateAnyOf(schema, instance);
    if (schema.oneOf.length > 0) _validateOneOf(schema, instance);
    if (schema.notSchema != null) _validateNot(schema, instance);
    if (schema.format != null) _validateFormat(schema, instance);
    if (instance.data is Map) _objectValidation(schema, instance);
  }

  bool _ifThenElseValidation(JsonSchema schema, Instance instance) {
    if (schema.ifSchema != null) {
      // Bail out early if no 'then' or 'else' schemas exist.
      if (schema.thenSchema == null && schema.elseSchema == null) return true;

      if (schema.ifSchema
          .validate(instance, reportMultipleErrors: _reportMultipleErrors)) {
        // Bail out early if no "then" is specified.
        if (schema.thenSchema == null) return true;
        if (!Validator(schema.thenSchema)
            .validate(instance, reportMultipleErrors: _reportMultipleErrors)) {
          _err(
              '${schema.path}/then: then violated ($instance, ${schema.thenSchema})',
              instance.path,
              schema.path + '/then');
        }
      } else {
        // Bail out early if no "else" is specified.
        if (schema.elseSchema == null) return true;
        if (!Validator(schema.elseSchema)
            .validate(instance, reportMultipleErrors: _reportMultipleErrors)) {
          _err(
              '${schema.path}/else: else violated ($instance, ${schema.elseSchema})',
              instance.path,
              schema.path + '/else');
        }
      }
      // Return early since we recursively call _validate in these cases.
      return true;
    }
    return false;
  }

  void _err(String msg, String instancePath, String schemaPath) {
    schemaPath = schemaPath.replaceFirst('#', '');
    _errors.add(ValidationError._(instancePath, schemaPath, msg));
    if (!_reportMultipleErrors) throw FormatException(msg);
  }
}
