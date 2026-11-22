import { useState, useCallback, useRef } from 'react';
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

  // Memoize AJV instance and compiled validator with useRef
  const ajvRef = useRef<Ajv | null>(null);
  const validateRef = useRef<any>(null);

  if (!ajvRef.current) {
    const instance = new Ajv({ allErrors: true, strict: false, verbose: true });
    addFormats(instance);
    ajvRef.current = instance;
    validateRef.current = instance.compile(appConfigSchema);
  }

  const validateJson = useCallback(() => {
    try {
      const parsed = JSON.parse(jsonText);
      const validate = validateRef.current;
      const valid = validate ? validate(parsed) : true;
      if (valid) {
        setErrors([]);
        setIsValid(true);
      } else {
        const validationErrors: ValidationError[] = (validate?.errors || []).map((err: any) => ({
          line: 0,
          column: 0,
          message: err.message || 'Validation error',
          keyword: err.keyword || '',
          instancePath: err.instancePath || '',
          schemaPath: err.schemaPath || '',
        }));

        // Calculate line/column from instancePath navigating nested JSON Pointer
        const lines = jsonText.split('\n');
        validationErrors.forEach(err => {
          if (err.instancePath) {
            const segments = err.instancePath.split('/').filter(Boolean);
            const targetProp = segments[segments.length - 1] || '';
            for (let i = 0; i < lines.length; i++) {
              const line = lines[i];
              const propIndex = line.indexOf(`"${targetProp}"`);
              if (propIndex !== -1) {
                err.line = i + 1;
                err.column = propIndex + 1;
                break;
              }
            }
          }
        });

        setErrors(validationErrors);
        setIsValid(false);
      }
    } catch (e: any) {
      // JSON parse error - find line/column
      let line = 1,
        column = 1;
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
      setErrors([
        {
          line,
          column,
          message: e.message || 'Invalid JSON',
          keyword: 'parse',
          instancePath: '',
          schemaPath: '',
        },
      ]);
      setIsValid(false);
    }
  }, [jsonText]);

  const resetErrors = useCallback(() => {
    setErrors([]);
    setIsValid(true);
  }, []);

  return { errors, isValid, validate: validateJson, resetErrors };
}
