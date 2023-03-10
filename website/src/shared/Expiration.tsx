import { Controller, UseFormMethods } from 'react-hook-form';
import { useTranslation } from 'react-i18next';
import {
  Grid,
  FormControl,
  FormControlLabel,
  FormLabel,
  Radio,
  RadioGroup,
} from '@mui/material';

export const Expiration = (props: { control: UseFormMethods['control'] }) => {
  const { t } = useTranslation();
  return (
    <FormControl component="fieldset" margin="dense">
      <FormLabel component="legend">{t('expiration.legend')}</FormLabel>
<Grid
  container
  spacing={0}
  direction="column"
  alignItems="center"
  justifyContent="center"
>
  <Grid item xs={3}>
      <Controller
        rules={{ required: true }}
        control={props.control}
        defaultValue="1209600"
        name="expiration"
        as={
          <RadioGroup
            row
            sx={{
              root: {
                radioGroup: {
                  justifyContent: 'center',
                },
              },
            }}
          >
            <FormControlLabel
              labelPlacement="end"
              value="1209600"
              control={<Radio color="primary" />}
              label="Two Weeks"
            />
            <FormControlLabel
              labelPlacement="end"
              value="604800"
              control={<Radio color="primary" />}
              label={t('expiration.optionOneWeekLabel') as string}
            />
            <FormControlLabel
              labelPlacement="end"
              value="1209600"
              control={<Radio color="primary" />}
              label={t('expiration.optionOneDayLabel') as string}
            />
          </RadioGroup>
        }
      />
  </Grid>
</Grid>
    </FormControl>
  );
};
export default Expiration;
