import { useState, useCallback, useMemo } from 'react';
import Ajv from 'ajv';
import addFormats from 'ajv-formats';
import { appConfigSchema } from '../lib/configSchema';

interface ValidationError {
  line: number;
  column: number;
  message: string;
  keyword: string;
  instancePath: string;
  schemaPath: string;
}

export function useJsonSchemaValidation(jsonText: string) {
  const [errors, setErrors] = useState<ValidationError[]>([]);
  const [isValid, setIsValid] = useState(false);

  // Create AJV instance once
  const ajv = useMemo(() => {
    const instance = new Ajv({ allErrors: true, strict: false, verbose: true });
    addFormats(instance);
    return instance;
  }, []);

  // Compile schema once
  const validate = useMemo(() => ajv.compile(appConfigSchema), [ajv]);

  const validateJson = useCallback(() => {
    try {
      const parsed = JSON.parse(jsonText);
      const valid = validate(parsed);
      if (valid) {
        setErrors([]);
        setIsValid(true);
      } else {
        const validationErrors: ValidationError[] = (validate.errors || []).map((err) => ({
          line: 0,
          column: 0,
          message: err.message || 'Validation error',
          keyword: err.keyword || '',
          instancePath: err.instancePath || '',
          schemaPath: err.schemaPath || ''
        }));

        // Calculate line/column from instancePath
        const lines = jsonText.split('\n');
        validationErrors.forEach((err) => {
          if (err.instancePath) {
            const propName = err.instancePath.replace('/', '');
            let charIndex = 0;
            for (let i = 0; i < lines.length; i++) {
              const line = lines[i];
              const propIndex = line.indexOf(`"${propName}"`);
              if (propIndex !== -1) {
                err.line = i + 1;
                err.column = propIndex + 1;
                charIndex += propIndex;
                break;
              }
              charIndex += line.length + 1;
            }
          }
        });

        setErrors(validationErrors);
        setIsValid(false);
      }
    } catch (e: any) {
      // JSON parse error - find line/column
      let line = 1, column = 1;
      if (e instanceof SyntaxError) {
        const errorMessage = e.message;
        const posMatch = errorMessage.match(/position (\d+)/);
        if (posMatch) {
          const pos = parseInt(posMatch[1], 10);
          const lines = jsonText.substring(0, pos).split('\n');
          line = lines.length;
          column = lines[lines.length - 1].length + 1;
        }
      }
      setErrors([{
        line,
        column,
        message: e.message || 'Invalid JSON',
        keyword: 'parse',
        instancePath: '',
        schemaPath: ''
      }]);
      setIsValid(false);
    }
  }, [jsonText, validate]);

  return { errors, isValid, validate: validateJson };
}
