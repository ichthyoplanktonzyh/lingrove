import {registerRoot} from 'remotion';
import {OpeningRoot} from './opening';
import React from 'react';
import {FilmRoot} from './film/root';
// Keep the earlier study available beside the new directions during editorial comparison.
registerRoot(() => React.createElement(React.Fragment, null, React.createElement(OpeningRoot), React.createElement(FilmRoot)));
