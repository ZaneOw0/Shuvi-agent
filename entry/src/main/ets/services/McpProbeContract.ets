// Named fields are checked at runtime after parsing; the declared shape alone is not validation.
class QuerySchema {
  type?: string;
}

class CountSchema {
  type?: string;
  minimum?: number;
  maximum?: number;
  default?: number;
}

class SearchProperties {
  query?: QuerySchema;
  maxResults?: CountSchema;
}

class SearchInputSchema {
  type?: string;
  additionalProperties?: boolean;
  properties?: SearchProperties;
  required?: string[];
}

export function validSearchProbeSchema(json: string): boolean {
  try {
    const schema: SearchInputSchema = JSON.parse(json);
    if (schema === null || typeof schema !== 'object' || Array.isArray(schema) ||
      schema.type !== 'object' || schema.additionalProperties !== false) return false;
    const properties = schema.properties;
    const required = schema.required;
    if (properties === undefined || properties === null || typeof properties !== 'object' ||
      Array.isArray(properties) || !Array.isArray(required) || required.length !== 1 ||
      required[0] !== 'query') return false;
    const keys: string[] = Object.keys(properties);
    if (keys.length !== 2 || keys.indexOf('query') < 0 || keys.indexOf('maxResults') < 0) return false;
    const query = properties.query;
    const count = properties.maxResults;
    return query !== undefined && query !== null && typeof query === 'object' &&
      !Array.isArray(query) && query.type === 'string' &&
      count !== undefined && count !== null && typeof count === 'object' &&
      !Array.isArray(count) && count.type === 'integer' && count.minimum === 1 &&
      count.maximum === 10 && count.default === 5;
  } catch (_error) {
    return false;
  }
}
